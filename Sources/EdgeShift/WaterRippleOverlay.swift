import AppKit
import CoreGraphics
import Metal
import MetalKit

@MainActor
final class WaterRippleOverlay: NSObject, MTKViewDelegate {
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let sampler: MTLSamplerState?
    private let fallbackTexture: MTLTexture?
    private let backdrop: RippleBackdrop?
    private var window: NSWindow?
    private var view: MTKView?
    private var displayID: CGDirectDisplayID?
    private var activeScreen: NSScreen?
    private var lastReducedMotion = false
    private var frameClock = RippleFrameClock()
    private var displayTransitionPending = false
    private var screenRefreshPending = false
    private var idleCleanup: DispatchWorkItem?
    private var previewTask: Task<Void, Never>?

    private var origin: SIMD2<Float> = .zero
    private var targetOrigin: SIMD2<Float> = .zero
    private var normal = SIMD2<Float>(1, 0)
    private var presence: Float = 0
    private var targetPresence: Float = 0
    private var strength: Float = 0
    private var targetStrength: Float = 0
    private var surfacePhase: Float = 0
    private var backdropMix: Float = 0
    private var waves: [RippleWave?] = [nil, nil]
    private var nextWave = 0

    override init() {
        let gpu = MTLCreateSystemDefaultDevice()
        device = gpu
        commandQueue = gpu?.makeCommandQueue()
        var renderPipeline: MTLRenderPipelineState?
        if let gpu {
            do { renderPipeline = try RippleShader.makePipeline(device: gpu) }
            catch { NSLog("EdgeShift ripple shader failed: %@", error.localizedDescription) }
        }
        pipeline = renderPipeline
        if let gpu {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            descriptor.sAddressMode = .clampToEdge
            descriptor.tAddressMode = .clampToEdge
            sampler = gpu.makeSamplerState(descriptor: descriptor)
            backdrop = RippleBackdrop(device: gpu)
            let texture = gpu.makeTexture(descriptor: .texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false))
            var clear: UInt32 = 0
            texture?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                             withBytes: &clear, bytesPerRow: 4)
            fallbackTexture = texture
        } else {
            sampler = nil
            fallbackTexture = nil
            backdrop = nil
        }
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func updatePush(at point: CGPoint, displayID: CGDirectDisplayID, edge: Side, progress: Double) {
        previewTask?.cancel()
        previewTask = nil
        applyPush(at: point, displayID: displayID, edge: edge, progress: progress)
    }

    private func applyPush(at point: CGPoint, displayID: CGDirectDisplayID, edge: Side, progress: Double) {
        guard let uv = normalizedUV(point, displayID: displayID), activate(displayID: displayID) != nil else { return }
        idleCleanup?.cancel()
        let direction = RippleMotion.normal(for: edge)
        if (targetPresence <= 0.01 && presence <= 0.01) || normal != direction {
            origin = uv
            if normal != direction { presence = 0; strength = 0 }
        }
        normal = direction
        targetOrigin = uv
        targetPresence = 1
        targetStrength = Float(min(max(progress, 0), 1))
    }

    func endPush() {
        previewTask?.cancel()
        previewTask = nil
        targetPresence = 0
        scheduleCleanup()
    }

    func cancelPreview() {
        guard previewTask != nil else { return }
        previewTask?.cancel()
        previewTask = nil
        targetPresence = 0
        scheduleCleanup()
    }

    func beginDisplayTransition() {
        previewTask?.cancel()
        previewTask = nil
        displayTransitionPending = true
        idleCleanup?.cancel()
        if presence > 0.003 || targetPresence > 0 {
            targetPresence = 1
            targetStrength = 1
        }
    }

    func endDisplayTransition() {
        displayTransitionPending = false
        if screenRefreshPending {
            screenRefreshPending = false
            screensChanged()
        }
    }

    func preview(displayID: CGDirectDisplayID, duration: TimeInterval) {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = CGPoint(x: bounds.minX, y: bounds.midY)
        updatePush(at: point, displayID: displayID, edge: .left, progress: 0)
        let start = CACurrentMediaTime()
        let chargingDuration = min(max(duration, 0.5), 2)
        previewTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let progress = (CACurrentMediaTime() - start) / chargingDuration
                guard progress < 1 else { break }
                self?.applyPush(at: point, displayID: displayID, edge: .left, progress: progress)
                do { try await Task.sleep(nanoseconds: 16_666_667) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self?.previewTask = nil
            self?.triggerHighlightWave(at: point, displayID: displayID, edge: .left)
        }
    }

    func triggerHighlightWave(at point: CGPoint, displayID: CGDirectDisplayID, edge: Side) {
        previewTask?.cancel()
        previewTask = nil
        guard let uv = normalizedUV(point, displayID: displayID),
              let screen = activate(displayID: displayID) else { return }
        let direction = RippleMotion.normal(for: edge)
        let hasCharge = presence > 0.003 && normal == direction
        let launchStrength = hasCharge ? strength : 1
        waves[nextWave] = RippleWave(
            origin: hasCharge ? origin : uv, normal: direction, startTime: frameClock.time,
            startRadius: RippleMotion.radius(strength: launchStrength),
            endRadius: Float(min(420, max(240, min(screen.frame.width, screen.frame.height) * 0.42))),
            presence: hasCharge ? presence : 1, strength: launchStrength,
            initialVelocity: hasCharge ? max(0, (targetStrength - strength) * 12 * 76) : 0)
        nextWave = (nextWave + 1) % waves.count
        // Transfer the current surface, including its radius and intensity, into
        // the travelling wave. No second ring appears back at the pointer.
        presence = 0
        targetPresence = 0
        scheduleCleanup()
    }

    private func normalizedUV(_ point: CGPoint, displayID: CGDirectDisplayID) -> SIMD2<Float>? {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return SIMD2(Float(min(max((point.x - bounds.minX) / bounds.width, 0), 1)),
                     Float(min(max((point.y - bounds.minY) / bounds.height, 0), 1)))
    }

    @discardableResult
    private func activate(displayID: CGDirectDisplayID) -> NSScreen? {
        // Mouse events can arrive much faster than frames. Capture and window
        // setup only need to run on activation or an actual screen change.
        if self.displayID == displayID, let activeScreen, window?.isVisible == true, view?.isPaused == false {
            return activeScreen
        }
        guard let device, pipeline != nil, let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return nil }
        if self.displayID != displayID {
            finish()
            self.displayID = displayID
        }
        activeScreen = screen
        if window == nil {
            let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.ignoresMouseEvents = true
            win.level = .screenSaver
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            win.isReleasedWhenClosed = false
            let metalView = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
            metalView.delegate = self
            metalView.wantsLayer = true
            metalView.layer?.isOpaque = false
            (metalView.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metalView.clearColor = MTLClearColorMake(0, 0, 0, 0)
            metalView.colorPixelFormat = .bgra8Unorm
            metalView.framebufferOnly = true
            metalView.isPaused = true
            win.contentView = metalView
            window = win
            view = metalView
        }
        if window?.frame != screen.frame {
            window?.setFrame(screen.frame, display: false)
            view?.frame = CGRect(origin: .zero, size: screen.frame.size)
        }
        // Match the display rather than requesting a non-divisor (120 on a
        // 165Hz screen is commonly scheduled by MetalKit at only 82.5fps).
        view?.preferredFramesPerSecond = screen.maximumFramesPerSecond > 0 ? screen.maximumFramesPerSecond : 60
        if window?.isVisible != true { window?.orderFrontRegardless() }
        if view?.isPaused != false { view?.isPaused = false }
        lastReducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !lastReducedMotion {
            backdrop?.start(displayID: displayID, screen: screen)
        } else {
            backdrop?.stop()
        }
        return screen
    }

    @objc private func screensChanged() {
        if displayTransitionPending { screenRefreshPending = true; return }
        activeScreen = nil
        if let displayID, view?.isPaused == false { activate(displayID: displayID) }
    }

    private func scheduleCleanup() {
        idleCleanup?.cancel()
        let cleanup = DispatchWorkItem { [weak self] in
            guard let self, self.targetPresence == 0 else { return }
            if self.waves.contains(where: { $0?.sample(at: self.frameClock.time) != nil }),
               let lastFrame = self.frameClock.lastPresentation, CACurrentMediaTime() - lastFrame < 0.25 {
                self.scheduleCleanup()
                return
            }
            // Also cleans up if an unplugged/sleeping screen stops supplying drawables.
            self.finish()
        }
        idleCleanup = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + RippleMotion.waveDuration + 0.25, execute: cleanup)
    }

    private func finish() {
        previewTask?.cancel()
        previewTask = nil
        idleCleanup?.cancel()
        idleCleanup = nil
        view?.isPaused = true
        window?.orderOut(nil)
        backdrop?.stop()
        waves = [nil, nil]
        presence = 0
        targetPresence = 0
        strength = 0
        targetStrength = 0
        surfacePhase = 0
        backdropMix = 0
        frameClock.reset()
        displayTransitionPending = false
        screenRefreshPending = false
        activeScreen = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let commandQueue, let pipeline, let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let commands = commandQueue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        let now = CACurrentMediaTime()
        let dt = frameClock.advance(to: now, frameInterval: 1 / Double(max(view.preferredFramesPerSecond, 1)))
        presence += (targetPresence - presence) * (1 - exp(-dt * (targetPresence > presence ? 11 : 12)))
        strength += (targetStrength - strength) * (1 - exp(-dt * 12))
        origin += (targetOrigin - origin) * (1 - exp(-dt * 18))
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduced { surfacePhase = (surfacePhase + dt * 1.4).truncatingRemainder(dividingBy: 2 * .pi) }
        if reduced != lastReducedMotion {
            lastReducedMotion = reduced
            if reduced { backdrop?.stop() }
            else if let displayID, let activeScreen { backdrop?.start(displayID: displayID, screen: activeScreen) }
        }

        var uniforms = RippleUniforms()
        uniforms.push = SIMD4(origin.x, origin.y, presence, strength)
        uniforms.pushStyle = SIMD4(normal.x, normal.y, surfacePhase, 0)
        var activeWave = false
        for index in waves.indices {
            if let sample = waves[index]?.sample(at: frameClock.time) {
                activeWave = true
                if index == 0 { uniforms.wave0 = sample.data; uniforms.wave0Style = sample.style }
                else { uniforms.wave1 = sample.data; uniforms.wave1Style = sample.style }
            } else { waves[index] = nil }
        }
        if presence <= 0.003 && targetPresence == 0 && !activeWave {
            encoder.endEncoding()
            commands.present(drawable)
            commands.commit()
            finish()
            return
        }
        let frame = backdrop?.latestFrame()
        backdropMix += ((frame == nil ? 0 : 1) - backdropMix) * (1 - exp(-dt * 16))
        uniforms.viewport = SIMD4(Float(view.bounds.width), Float(view.bounds.height),
                                  frame == nil ? 0 : backdropMix, reduced ? 1 : 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RippleUniforms>.stride, index: 0)
        encoder.setFragmentTexture(frame?.texture ?? fallbackTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        if let region = uniforms.pixelBounds(drawableSize: view.drawableSize) {
            encoder.setScissorRect(MTLScissorRect(x: Int(region.minX), y: Int(region.minY),
                                                width: Int(region.width), height: Int(region.height)))
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        // Keep the CVPixelBuffer/IOSurface alive until Metal has finished sampling.
        commands.addCompletedHandler { _ in withExtendedLifetime(frame) {} }
        commands.present(drawable)
        commands.commit()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
