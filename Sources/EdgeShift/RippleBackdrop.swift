import AppKit
import CoreMedia
import CoreVideo
import Metal
import ScreenCaptureKit

// The IOSurface and its Core Video wrapper must outlive the GPU command that
// samples them. The renderer retains this object until command-buffer completion.
// Immutable after creation; the completion queue only retains/releases it.
final class RippleBackdropFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let metalTexture: CVMetalTexture
    let texture: MTLTexture

    init(pixelBuffer: CVPixelBuffer, metalTexture: CVMetalTexture, texture: MTLTexture) {
        self.pixelBuffer = pixelBuffer
        self.metalTexture = metalTexture
        self.texture = texture
    }
}

// ScreenCaptureKit invokes this on a serial capture queue. Keep only the newest
// complete frame, so a slow draw never builds a queue of old desktop images.
private final class RippleFrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var pendingBuffer: CVPixelBuffer?
    private var accepting = true
    private var hasValidContent = false

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return }
        switch status {
        case .complete:
            if let buffer = sampleBuffer.imageBuffer {
                pendingBuffer = buffer
                hasValidContent = true
            }
        case .idle:
            break // A static desktop is still valid; do not flash back to the fallback.
        default:
            // Keep the last valid frame across brief WindowServer transitions during display rearrangement.
            pendingBuffer = nil
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { invalidate() }

    func invalidate() {
        lock.lock()
        accepting = false
        hasValidContent = false
        pendingBuffer = nil
        lock.unlock()
    }

    func takeLatest() -> (valid: Bool, buffer: CVPixelBuffer?) {
        lock.lock()
        defer { lock.unlock() }
        let buffer = pendingBuffer
        pendingBuffer = nil
        return (accepting && hasValidContent, buffer)
    }
}

@MainActor
final class RippleBackdrop {
    private struct Target: Equatable {
        let displayID: CGDirectDisplayID
        let width: Int
        let height: Int
        let fps: Int
    }

    private let device: MTLDevice
    private var cache: CVMetalTextureCache?
    private let captureQueue = DispatchQueue(label: "com.edgeshift.ripple-backdrop", qos: .userInteractive)
    private var target: Target?
    private var generation = 0
    private var startup: Task<Void, Never>?
    private var stream: SCStream?
    private var receiver: RippleFrameReceiver?
    private var frame: RippleBackdropFrame?

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    }

    func start(displayID: CGDirectDisplayID, screen: NSScreen) {
        guard CGPreflightScreenCaptureAccess(), cache != nil else {
            if target != nil { stop() }
            return
        }
        let size = screen.frame.size
        // Cap captured backdrop resolution/rate so GPU refraction stays smooth at 120Hz without bandwidth stalls.
        let scale = min(screen.backingScaleFactor, 1600 / max(size.width, size.height))
        let next = Target(displayID: displayID, width: max(1, Int((size.width * scale).rounded())),
                          height: max(1, Int((size.height * scale).rounded())),
                          fps: 60)
        guard target != next else { return }
        stop()
        target = next
        let ticket = generation
        startup = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !Task.isCancelled, let self, self.generation == ticket,
                      let display = content.displays.first(where: { $0.displayID == next.displayID }) else { return }
                // Exclude the application, including windows created after capture
                // starts, so the ripple never feeds its own image back into itself.
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.width = next.width
                config.height = next.height
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(next.fps))
                config.queueDepth = 3
                config.showsCursor = false
                config.capturesAudio = false
                let output = RippleFrameReceiver()
                let newStream = SCStream(filter: filter, configuration: config, delegate: output)
                try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: self.captureQueue)
                self.receiver = output
                do {
                    try await newStream.startCapture()
                } catch {
                    output.invalidate()
                    try? await newStream.stopCapture()
                    throw error
                }
                guard !Task.isCancelled, self.generation == ticket else {
                    output.invalidate()
                    try? await newStream.stopCapture()
                    return
                }
                self.stream = newStream
                self.startup = nil
            } catch {
                guard let self, self.generation == ticket else { return }
                self.receiver?.invalidate()
                self.receiver = nil
                self.frame = nil
                self.startup = nil
                NSLog("EdgeShift ripple backdrop unavailable: %@", error.localizedDescription)
            }
        }
    }

    func latestFrame() -> RippleBackdropFrame? {
        guard let receiver, let cache else { return frame }
        let latest = receiver.takeLatest()
        if !latest.valid { frame = nil; return nil }
        if let buffer = latest.buffer {
            var wrapper: CVMetalTexture?
            let result = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm,
                CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &wrapper)
            if result == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) {
                frame = RippleBackdropFrame(pixelBuffer: buffer, metalTexture: wrapper, texture: texture)
            }
        }
        return frame
    }

    func stop() {
        guard target != nil || startup != nil || stream != nil || receiver != nil || frame != nil else { return }
        generation &+= 1
        startup?.cancel()
        startup = nil
        receiver?.invalidate()
        receiver = nil
        frame = nil
        target = nil
        if let stream {
            self.stream = nil
            stream.stopCapture { _ in }
        }
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
    }

    deinit {
        startup?.cancel()
        receiver?.invalidate()
        stream?.stopCapture { _ in }
    }
}
