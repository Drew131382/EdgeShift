import AppKit
import CoreGraphics
import Metal
import MetalKit

private struct RippleRenderResources {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let fallbackTexture: MTLTexture?
}

@MainActor
final class WaterRippleOverlay {
    private let resources: RippleRenderResources?
    private var layers: [CGDirectDisplayID: DisplayRippleLayer] = [:]
    private var activePushDisplayID: CGDirectDisplayID?
    private var previewDisplayID: CGDirectDisplayID?
    private var previewTask: Task<Void, Never>?
    private var displayTransitionPending = false
    private var screenRefreshPending = false

    init() {
        if let gpu = MTLCreateSystemDefaultDevice(),
           let commandQueue = gpu.makeCommandQueue() {
            var renderPipeline: MTLRenderPipelineState?
            do { renderPipeline = try RippleShader.makePipeline(device: gpu) }
            catch { NSLog("EdgeShift ripple shader failed: %@", error.localizedDescription) }
            if let renderPipeline {
                let descriptor = MTLSamplerDescriptor()
                descriptor.minFilter = .linear
                descriptor.magFilter = .linear
                descriptor.sAddressMode = .clampToEdge
                descriptor.tAddressMode = .clampToEdge
                if let sampler = gpu.makeSamplerState(descriptor: descriptor) {
                    let texture = gpu.makeTexture(descriptor: .texture2DDescriptor(
                        pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false))
                    var clear: UInt32 = 0
                    texture?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                                     withBytes: &clear, bytesPerRow: 4)
                    resources = RippleRenderResources(
                        device: gpu,
                        commandQueue: commandQueue,
                        pipeline: renderPipeline,
                        sampler: sampler,
                        fallbackTexture: texture
                    )
                } else {
                    resources = nil
                }
            } else {
                resources = nil
            }
        } else {
            resources = nil
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func layer(for displayID: CGDirectDisplayID) -> DisplayRippleLayer? {
        if let existing = layers[displayID] { return existing }
        guard let resources else { return nil }
        let created = DisplayRippleLayer(displayID: displayID, resources: resources)
        layers[displayID] = created
        return created
    }

    func updatePush(at point: CGPoint, displayID: CGDirectDisplayID, edge: Side, progress: Double) {
        cancelPreviewTaskOnly()
        if let previous = activePushDisplayID, previous != displayID {
            layers[previous]?.endPush()
        }
        activePushDisplayID = displayID
        layer(for: displayID)?.applyPush(at: point, edge: edge, progress: progress)
    }

    func endPush() {
        cancelPreviewTaskOnly()
        if let id = activePushDisplayID {
            layers[id]?.endPush()
            activePushDisplayID = nil
        }
    }

    func cancelPreview() {
        guard previewTask != nil || previewDisplayID != nil else { return }
        cancelPreviewTaskOnly()
        if let id = previewDisplayID {
            layers[id]?.endPush()
            if activePushDisplayID == id { activePushDisplayID = nil }
            previewDisplayID = nil
        }
    }

    func stopAll() {
        cancelPreviewTaskOnly()
        activePushDisplayID = nil
        previewDisplayID = nil
        displayTransitionPending = false
        screenRefreshPending = false
        for layer in layers.values {
            layer.finish()
        }
    }

    func beginDisplayTransition() {
        cancelPreviewTaskOnly()
        previewDisplayID = nil
        displayTransitionPending = true
        if let id = activePushDisplayID {
            layers[id]?.beginTransitionIfCharging()
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
        cancelPreview()
        let point = CGPoint(x: bounds.minX, y: bounds.midY)
        previewDisplayID = displayID
        updatePush(at: point, displayID: displayID, edge: .left, progress: 0)
        let start = CACurrentMediaTime()
        let chargingDuration = min(max(duration, 0.5), 2)
        previewTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let progress = (CACurrentMediaTime() - start) / chargingDuration
                guard progress < 1 else { break }
                self?.layer(for: displayID)?.applyPush(at: point, edge: .left, progress: progress)
                do { try await Task.sleep(nanoseconds: 16_666_667) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self?.previewTask = nil
            self?.previewDisplayID = nil
            self?.triggerHighlightWave(at: point, displayID: displayID, edge: .left)
        }
    }

    func triggerHighlightWave(at point: CGPoint, displayID: CGDirectDisplayID, edge: Side) {
        cancelPreviewTaskOnly()
        previewDisplayID = nil
        if activePushDisplayID == displayID { activePushDisplayID = nil }
        layer(for: displayID)?.triggerHighlightWave(at: point, edge: edge)
    }

    func triggerSwitchRipples(mainPoint: CGPoint, mainDisplayID: CGDirectDisplayID, mainEdge: Side,
                              secondaryPoint: CGPoint, secondaryDisplayID: CGDirectDisplayID, secondaryEdge: Side) {
        cancelPreview()
        if activePushDisplayID == mainDisplayID { activePushDisplayID = nil }
        layer(for: mainDisplayID)?.triggerHighlightWave(at: mainPoint, edge: mainEdge)
        layer(for: secondaryDisplayID)?.triggerHighlightWave(at: secondaryPoint, edge: secondaryEdge)
    }

    private func cancelPreviewTaskOnly() {
        previewTask?.cancel()
        previewTask = nil
    }

    @objc private func screensChanged() {
        if displayTransitionPending { screenRefreshPending = true; return }
        let connectedIDs = Set(NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        })
        for id in Array(layers.keys) {
            guard let layer = layers[id] else { continue }
            if !connectedIDs.contains(id) {
                layer.finish()
                layers.removeValue(forKey: id)
                if activePushDisplayID == id { activePushDisplayID = nil }
                if previewDisplayID == id { previewDisplayID = nil }
            } else {
                layer.refreshScreen()
            }
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

@MainActor
private final class DisplayRippleLayer: NSObject, MTKViewDelegate {
    let displayID: CGDirectDisplayID
    private let resources: RippleRenderResources
    private let backdrop: RippleBackdrop
    private var window: NSWindow?
    private var view: MTKView?
    private var activeScreen: NSScreen?
    private var lastReducedMotion = false
    private var frameClock = RippleFrameClock()
    private var idleCleanup: DispatchWorkItem?

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

    init(displayID: CGDirectDisplayID, resources: RippleRenderResources) {
        self.displayID = displayID
        self.resources = resources
        self.backdrop = RippleBackdrop(device: resources.device)
        super.init()
    }

    func applyPush(at point: CGPoint, edge: Side, progress: Double) {
        guard let uv = normalizedUV(point), activate() != nil else { return }
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
        targetPresence = 0
        scheduleCleanup()
    }

    func beginTransitionIfCharging() {
        idleCleanup?.cancel()
        if presence > 0.003 || targetPresence > 0 {
            targetPresence = 1
            targetStrength = 1
        }
    }

    func triggerHighlightWave(at point: CGPoint, edge: Side) {
        guard let uv = normalizedUV(point), let screen = activate() else { return }
        idleCleanup?.cancel()
        let direction = RippleMotion.normal(for: edge)
        let hasCharge = presence > 0.003 && normal == direction
        let launchStrength: Float = hasCharge ? strength : 1
        let startRadius = hasCharge ? RippleMotion.radius(strength: launchStrength) : RippleMotion.radius(strength: 0)
        waves[nextWave] = RippleWave(
            origin: hasCharge ? origin : uv, normal: direction, startTime: frameClock.time,
            startRadius: startRadius,
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

    func refreshScreen() {
        activeScreen = nil
        if view?.isPaused == false { activate() }
    }

    private func normalizedUV(_ point: CGPoint) -> SIMD2<Float>? {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return SIMD2(Float(min(max((point.x - bounds.minX) / bounds.width, 0), 1)),
                     Float(min(max((point.y - bounds.minY) / bounds.height, 0), 1)))
    }

    private func cocoaFrame(for screen: NSScreen) -> CGRect {
        let cg = CGDisplayBounds(displayID)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        guard cg.width > 0, cg.height > 0, primaryHeight > 0 else { return screen.frame }
        return CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
    }

    @discardableResult
    private func activate() -> NSScreen? {
        // Mouse events can arrive much faster than frames. Capture and window
        // setup only need to run on activation or an actual screen change.
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return nil }
        let targetFrame = cocoaFrame(for: screen)
        if let activeScreen, window?.isVisible == true, view?.isPaused == false, window?.frame == targetFrame {
            return activeScreen
        }
        activeScreen = screen
        if window == nil {
            let win = NSWindow(contentRect: targetFrame, styleMask: .borderless, backing: .buffered, defer: false)
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.ignoresMouseEvents = true
            win.level = .screenSaver
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            win.isReleasedWhenClosed = false
            let metalView = MTKView(frame: CGRect(origin: .zero, size: targetFrame.size), device: resources.device)
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
        if window?.frame != targetFrame {
            window?.setFrame(targetFrame, display: false)
            view?.frame = CGRect(origin: .zero, size: targetFrame.size)
        }
        // Match the display rather than requesting a non-divisor (120 on a
        // 165Hz screen is commonly scheduled by MetalKit at only 82.5fps).
        view?.preferredFramesPerSecond = screen.maximumFramesPerSecond > 0 ? screen.maximumFramesPerSecond : 60
        if window?.isVisible != true { window?.orderFrontRegardless() }
        if view?.isPaused != false { view?.isPaused = false }
        lastReducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !lastReducedMotion {
            backdrop.start(displayID: displayID, screen: screen)
        } else {
            backdrop.stop()
        }
        return screen
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

    func finish() {
        idleCleanup?.cancel()
        idleCleanup = nil
        view?.isPaused = true
        window?.orderOut(nil)
        backdrop.stop()
        waves = [nil, nil]
        presence = 0
        targetPresence = 0
        strength = 0
        targetStrength = 0
        surfacePhase = 0
        backdropMix = 0
        frameClock.reset()
        activeScreen = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = resources.commandQueue.makeCommandBuffer(),
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
            if reduced { backdrop.stop() }
            else if let activeScreen { backdrop.start(displayID: displayID, screen: activeScreen) }
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
        let frame = backdrop.latestFrame()
        backdropMix += ((frame == nil ? 0 : 1) - backdropMix) * (1 - exp(-dt * 16))
        uniforms.viewport = SIMD4(Float(view.bounds.width), Float(view.bounds.height),
                                  frame == nil ? 0 : backdropMix, reduced ? 1 : 0)
        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RippleUniforms>.stride, index: 0)
        encoder.setFragmentTexture(frame?.texture ?? resources.fallbackTexture, index: 0)
        encoder.setFragmentSamplerState(resources.sampler, index: 0)
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
}
