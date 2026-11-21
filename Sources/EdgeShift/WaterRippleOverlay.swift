import AppKit
import CoreGraphics
import Metal
import MetalKit
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

private struct RippleUniforms {
    var pushData: SIMD4<Float>   // xy = origin, z = presence, w = strength
    var meta: SIMD4<Float>       // x = time, y = aspect, z = hasBackdrop, w = 0
    var wave0: SIMD4<Float>      // xy = origin, z = progress (< 0 inactive), w = maxRadius
    var wave1: SIMD4<Float>      // xy = origin, z = progress (< 0 inactive), w = maxRadius
}

private struct WaveSlot {
    var origin: SIMD2<Float> = .zero
    var startTime: CFTimeInterval = 0
    var maxRadius: Float = 1.6
    var active: Bool = false
}

@MainActor
final class WaterRippleOverlay: NSObject, MTKViewDelegate {
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLRenderPipelineState?
    private let backdropSampler: MTLSamplerState?
    private let fallbackTexture: MTLTexture?

    private var backdropTexture: MTLTexture?
    private var backdropDisplayID: CGDirectDisplayID = 0
    private var backdropCapturedAt: CFTimeInterval = 0
    private var backdropCaptureInFlight = false

    private var window: NSWindow?
    private var mtkView: MTKView?
    private var lastFrameTime: CFTimeInterval = 0

    // Charging push state (smoothly interpolated in draw loop, never pops in or out).
    private var pushOrigin: SIMD2<Float> = .zero
    private var targetPushOrigin: SIMD2<Float> = .zero
    private var pushPresence: Float = 0
    private var targetPushPresence: Float = 0
    private var pushStrength: Float = 0
    private var targetPushStrength: Float = 0

    // Highlight breakthrough waves (2 slots so rapid crossings never cut off an active wave).
    private var waves: [WaveSlot] = [WaveSlot(), WaveSlot()]
    private var nextWaveSlot = 0
    private let waveDuration: CFTimeInterval = 0.68

    override init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        self.pipelineState = device.flatMap(Self.makePipeline(device:))
        self.backdropSampler = device.flatMap(Self.makeSampler(device:))
        self.fallbackTexture = device.flatMap(Self.makeFallbackTexture(device:))
        super.init()
    }

    func updatePush(at cgPoint: CGPoint, displayID: CGDirectDisplayID, progress: Double) {
        guard let uv = normalizedUV(for: cgPoint, displayID: displayID) else { return }
        if targetPushPresence <= 0.01 && pushPresence <= 0.01 {
            pushOrigin = uv
        }
        targetPushOrigin = uv
        targetPushPresence = 1.0
        targetPushStrength = Float(min(max(progress, 0.0), 1.0))

        ensureActive(displayID: displayID)
    }

    func endPush() {
        targetPushPresence = 0.0
    }

    func triggerHighlightWave(at cgPoint: CGPoint, displayID: CGDirectDisplayID) {
        guard let uv = normalizedUV(for: cgPoint, displayID: displayID) else { return }
        let maxR: Float = 0.34

        // Dissolve any charging dome seamlessly into the expanding highlight wave.
        targetPushPresence = 0.0

        waves[nextWaveSlot] = WaveSlot(
            origin: uv,
            startTime: CACurrentMediaTime(),
            maxRadius: maxR,
            active: true
        )
        nextWaveSlot = (nextWaveSlot + 1) % waves.count

        ensureActive(displayID: displayID, forceBackdropRefresh: true)
    }

    private func normalizedUV(for cgPoint: CGPoint, displayID: CGDirectDisplayID) -> SIMD2<Float>? {
        let cgBounds = CGDisplayBounds(displayID)
        guard cgBounds.width > 0, cgBounds.height > 0 else { return nil }
        let u = min(max(Float((cgPoint.x - cgBounds.minX) / cgBounds.width), 0), 1)
        let v = min(max(Float((cgPoint.y - cgBounds.minY) / cgBounds.height), 0), 1)
        return SIMD2<Float>(u, v)
    }

    private func ensureActive(displayID: CGDirectDisplayID, forceBackdropRefresh: Bool = false) {
        guard let device, pipelineState != nil else { return }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return }

        ensureOverlayWindow(for: screen, device: device)
        if lastFrameTime == 0 { lastFrameTime = CACurrentMediaTime() }
        mtkView?.isPaused = false
        window?.orderFrontRegardless()

        refreshBackdropIfAuthorized(displayID: displayID, device: device, force: forceBackdropRefresh)
    }

    private func refreshBackdropIfAuthorized(displayID: CGDirectDisplayID, device: MTLDevice, force: Bool) {
        guard #available(macOS 14.0, *), CGPreflightScreenCaptureAccess() else { return }
        let now = CACurrentMediaTime()
        if !force, backdropDisplayID == displayID, backdropTexture != nil, now - backdropCapturedAt < 0.8 {
            return
        }
        guard !backdropCaptureInFlight else { return }
        backdropCaptureInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.backdropCaptureInFlight = false }
            guard let self else { return }
            if let tex = await Self.captureBackdrop(displayID: displayID, device: device) {
                self.backdropTexture = tex
                self.backdropDisplayID = displayID
                self.backdropCapturedAt = CACurrentMediaTime()
            }
        }
    }

    private func ensureOverlayWindow(for screen: NSScreen, device: MTLDevice) {
        if window == nil {
            let win = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.ignoresMouseEvents = true
            win.level = .screenSaver
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            win.isReleasedWhenClosed = false

            let view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
            view.delegate = self
            view.wantsLayer = true
            view.layer?.isOpaque = false
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = true
            view.preferredFramesPerSecond = 120
            view.isPaused = true
            view.enableSetNeedsDisplay = false

            win.contentView = view
            self.window = win
            self.mtkView = view
        } else if window?.frame != screen.frame {
            window?.setFrame(screen.frame, display: false)
            mtkView?.frame = CGRect(origin: .zero, size: screen.frame.size)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let commandQueue,
              let pipelineState,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 0.0), 0.05))
        lastFrameTime = now

        // Smooth exponential interpolation so every start, build-up, and fade-out is seamless.
        let presenceRate: Float = targetPushPresence > pushPresence ? 11.0 : 6.5
        pushPresence += (targetPushPresence - pushPresence) * (1.0 - exp(-dt * presenceRate))
        pushStrength += (targetPushStrength - pushStrength) * (1.0 - exp(-dt * 12.0))
        pushOrigin += (targetPushOrigin - pushOrigin) * (1.0 - exp(-dt * 18.0))

        var waveUniforms: [SIMD4<Float>] = []
        var anyWaveActive = false
        for i in waves.indices {
            if waves[i].active {
                let p = Float((now - waves[i].startTime) / waveDuration)
                if p >= 1.0 {
                    waves[i].active = false
                    waveUniforms.append(SIMD4<Float>(0, 0, -1, 1))
                } else {
                    anyWaveActive = true
                    waveUniforms.append(SIMD4<Float>(waves[i].origin.x, waves[i].origin.y, max(0, p), waves[i].maxRadius))
                }
            } else {
                waveUniforms.append(SIMD4<Float>(0, 0, -1, 1))
            }
        }

        let pushActive = pushPresence > 0.003 || targetPushPresence > 0.003
        if !pushActive && !anyWaveActive {
            pushPresence = 0
            pushStrength = 0
            lastFrameTime = 0
            view.isPaused = true
            backdropTexture = nil
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
                encoder.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            window?.orderOut(nil)
            return
        }

        let aspect = Float(view.drawableSize.width / max(1.0, view.drawableSize.height))
        var uniforms = RippleUniforms(
            pushData: SIMD4<Float>(pushOrigin.x, pushOrigin.y, pushPresence, pushStrength),
            meta: SIMD4<Float>(Float(now.truncatingRemainder(dividingBy: 1000.0)), aspect, backdropTexture != nil ? 1.0 : 0.0, 0),
            wave0: waveUniforms[0],
            wave1: waveUniforms[1]
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RippleUniforms>.stride, index: 0)
        encoder.setFragmentTexture(backdropTexture ?? fallbackTexture, index: 0)
        if let backdropSampler {
            encoder.setFragmentSamplerState(backdropSampler, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    @available(macOS 14.0, *)
    private static func captureBackdrop(displayID: CGDirectDisplayID, device: MTLDevice) async -> MTLTexture? {
        #if canImport(ScreenCaptureKit)
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
            return nil
        }
        let loader = MTKTextureLoader(device: device)
        return try? await loader.newTexture(cgImage: cgImage, options: [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
        ])
        #else
        return nil
        #endif
    }

    private static func makeSampler(device: MTLDevice) -> MTLSamplerState? {
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: desc)
    }

    private static func makeFallbackTexture(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var pixel: [UInt8] = [0, 0, 0, 0]
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        return tex
    }

    private static func makePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vertexFunc = library.makeFunction(name: "rippleVertex"),
              let fragmentFunc = library.makeFunction(name: "rippleFragment") else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFunc
        desc.fragmentFunction = fragmentFunc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct RippleUniforms {
        float4 pushData; // xy = origin, z = presence, w = strength
        float4 meta;     // x = time, y = aspect, z = hasBackdrop, w = 0
        float4 wave0;    // xy = origin, z = progress (< 0 inactive), w = maxRadius
        float4 wave1;    // xy = origin, z = progress (< 0 inactive), w = maxRadius
    };

    vertex VertexOut rippleVertex(uint vid [[vertex_id]]) {
        float2 positions[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };
        VertexOut out;
        float2 pos = positions[vid];
        out.position = float4(pos, 0.0, 1.0);
        out.uv = float2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5);
        return out;
    }

    static inline float fluidBand(float d, float r, float wFront, float wBack) {
        float diff = d - r;
        float w = diff >= 0.0 ? wFront : wBack;
        float x = diff / max(w, 0.0001);
        return exp(-x * x);
    }

    struct RippleContribution {
        float3 glassColor;
        float glassAlpha;
        float2 dispUV;
        float refrMask;
    };

    static inline RippleContribution evalHighlightWave(
        float2 uv,
        float4 wave,
        float aspect
    ) {
        RippleContribution res;
        res.glassColor = float3(0.0);
        res.glassAlpha = 0.0;
        res.dispUV = float2(0.0);
        res.refrMask = 0.0;

        float t = wave.z;
        if (t < 0.0 || t >= 1.0) { return res; }

        float eased = 1.0 - pow(1.0 - t, 3.6);
        float2 delta = float2((uv.x - wave.x) * aspect, uv.y - wave.y);
        float dist = length(delta);
        float maxR = wave.w;
        if (dist > maxR * 1.05) { return res; }
        float2 dir = dist > 1e-5 ? delta / dist : float2(0.0, 0.0);
        float angle = atan2(delta.y, delta.x);

        float fluidWobble = (sin(angle * 3.0 + t * 5.0) * 0.0045
                           + sin(angle * 7.0 - t * 6.5) * 0.0025
                           + cos(angle * 11.0 + t * 4.0) * 0.0012)
                          * smoothstep(0.0, 0.04, dist);
        float d = dist + fluidWobble * smoothstep(0.0, 0.22, t);

        float r1 = mix(0.0, maxR, eased);
        float w1Front = mix(0.014, 0.026, eased);
        float w1Back  = mix(0.028, 0.062, eased);
        float w1 = fluidBand(d, r1, w1Front, w1Back);

        float r2 = r1 * 0.76;
        float w2 = fluidBand(d, r2, w1Front * 0.85, w1Back * 0.78) * 0.48 * smoothstep(0.04, 0.20, t);

        float r3 = r1 * 0.54;
        float w3 = fluidBand(d, r3, w1Front * 0.75, w1Back * 0.65) * 0.24 * smoothstep(0.10, 0.32, t);

        float combinedWave = w1 + w2 + w3;

        float diff1 = d - r1;
        float activeW1 = diff1 >= 0.0 ? w1Front : w1Back;
        float slope1 = -2.0 * diff1 / max(activeW1 * activeW1, 0.0001) * w1;

        float diff2 = d - r2;
        float activeW2 = diff2 >= 0.0 ? w1Front * 0.85 : w1Back * 0.78;
        float slope2 = -2.0 * diff2 / max(activeW2 * activeW2, 0.0001) * w2;

        float slope = clamp((slope1 + slope2 * 0.6) * 0.020, -1.0, 1.0);

        // Smooth fade-in, radial distance attenuation, and graceful temporal fade-out.
        float timeEnvelope = smoothstep(0.0, 0.06, t) * (1.0 - smoothstep(0.38, 1.0, t));
        float spatialDecay = exp(-pow(d / max(maxR * 0.70, 0.01), 2.0) * 1.9)
                           * (1.0 - smoothstep(maxR * 0.62, maxR, d));
        float envelope = timeEnvelope * spatialDecay;
        float caustic = 0.88 + 0.12 * sin(angle * 13.0 + t * 10.0) * cos(angle * 5.0 - t * 6.0);
        float contactBloom = exp(-dist * 14.0) * smoothstep(0.0, 0.04, t) * (1.0 - smoothstep(0.08, 0.36, t));

        float outerFringe = max(0.0, -slope);
        float innerFringe = max(0.0, slope);

        float3 pearlWhite = float3(1.0, 1.0, 1.0);
        float3 frostedIce = float3(0.78, 0.91, 1.0);
        float3 cyanDisp   = float3(0.42, 0.90, 1.0);
        float3 roseViolet = float3(0.86, 0.64, 1.0);

        // Extra luminous highlight ridge for the post-crossing breakthrough wave.
        float crestCore = pow(clamp(w1, 0.0, 1.0), 1.85) * caustic;
        float highlightFlash = pow(clamp(w1, 0.0, 1.0), 3.4) * (1.0 - smoothstep(0.15, 0.75, t));
        float frostedWake = clamp(combinedWave * 0.70, 0.0, 1.0);

        res.glassColor = (pearlWhite * (crestCore * 1.15 + highlightFlash * 0.65)
                        + frostedIce * frostedWake * 0.48
                        + cyanDisp * outerFringe * 0.62
                        + roseViolet * innerFringe * 0.46
                        + pearlWhite * contactBloom * 1.05) * envelope;

        res.glassAlpha = clamp(
            (crestCore * 0.80 + highlightFlash * 0.30 + frostedWake * 0.36 + (outerFringe + innerFringe) * 0.28 + contactBloom * 0.70) * envelope,
            0.0,
            0.96
        );

        float dispStrength = (0.044 * (1.0 - 0.32 * eased)) * envelope;
        float2 dirUV = float2(dir.x / max(aspect, 0.001), dir.y);
        res.dispUV = dirUV * slope * dispStrength;
        res.refrMask = clamp(combinedWave * envelope * 1.30, 0.0, 1.0);
        return res;
    }

    static inline RippleContribution evalChargingPush(
        float2 uv,
        float4 pushData,
        float time,
        float aspect
    ) {
        RippleContribution res;
        res.glassColor = float3(0.0);
        res.glassAlpha = 0.0;
        res.dispUV = float2(0.0);
        res.refrMask = 0.0;

        float presence = clamp(pushData.z, 0.0, 1.0);
        if (presence <= 0.002) { return res; }

        float strength = clamp(pushData.w, 0.0, 1.0);
        float intensity = mix(0.40, 1.0, pow(strength, 0.85));

        float2 delta = float2((uv.x - pushData.x) * aspect, uv.y - pushData.y);
        float dist = length(delta);
        float reach = mix(0.11, 0.25, strength);
        if (dist > reach * 1.40) { return res; }
        float2 dir = dist > 1e-5 ? delta / dist : float2(0.0, 0.0);
        float angle = atan2(delta.y, delta.x);

        // Keep center contact dome smooth and round; gently undulate outer ripples.
        float wobble = (sin(angle * 4.0 + time * 4.2) * 0.003
                      + sin(angle * 7.0 - time * 3.1) * 0.0018)
                     * smoothstep(0.0, 0.05, dist);
        float d = dist + wobble * (0.35 + 0.65 * strength);

        float spatialMask = 1.0 - smoothstep(reach * 0.85, reach * 1.35, d);
        float radialDecay = exp(-pow(d / max(reach, 0.01), 1.85) * 2.1) * spatialMask;

        // Soft liquid-glass edge meniscus dome that grows as time accumulates.
        float dome = exp(-pow(d / mix(0.048, 0.115, strength), 1.65)) * spatialMask;

        // Continuous outward-emanating water ripples from the contact point.
        float freq = mix(26.0, 34.0, strength);
        float speed = mix(4.2, 8.2, strength);
        float phase = d * freq - time * speed;
        float waveRings = pow(0.5 + 0.5 * sin(phase), 3.0) * smoothstep(0.006, 0.035, d) * radialDecay;
        float ringSlope = cos(phase) * smoothstep(0.006, 0.035, d) * radialDecay * 0.55;

        float3 pearlWhite = float3(0.98, 0.995, 1.0);
        float3 frostedIce = float3(0.72, 0.88, 1.0);
        float3 cyanTint   = float3(0.40, 0.88, 1.0);
        float3 violetTint = float3(0.80, 0.60, 1.0);

        float outerFringe = max(0.0, -ringSlope);
        float innerFringe = max(0.0, ringSlope);

        float vis = presence * intensity;
        res.glassColor = (pearlWhite * (dome * 0.62 + waveRings * 0.72)
                        + frostedIce * (dome * 0.35 + radialDecay * 0.25)
                        + cyanTint * outerFringe * 0.45
                        + violetTint * innerFringe * 0.35) * vis;

        res.glassAlpha = clamp((dome * 0.48 + waveRings * 0.42 + radialDecay * 0.16) * vis, 0.0, 0.88);

        float2 dirUV = float2(dir.x / max(aspect, 0.001), dir.y);
        res.dispUV = dirUV * ringSlope * 0.022 * vis;
        res.refrMask = clamp((dome * 0.5 + waveRings * 0.9) * vis, 0.0, 1.0);
        return res;
    }

    fragment float4 rippleFragment(
        VertexOut in [[stage_in]],
        constant RippleUniforms& u [[buffer(0)]],
        texture2d<float> backdrop [[texture(0)]],
        sampler backdropSampler [[sampler(0)]]
    ) {
        float time = u.meta.x;
        float aspect = u.meta.y;
        float hasBackdrop = u.meta.z;

        RippleContribution charge = evalChargingPush(in.uv, u.pushData, time, aspect);
        RippleContribution w0 = evalHighlightWave(in.uv, u.wave0, aspect);
        RippleContribution w1 = evalHighlightWave(in.uv, u.wave1, aspect);

        float3 totalGlass = charge.glassColor + w0.glassColor + w1.glassColor;
        float glassAlpha = clamp(max(charge.glassAlpha, max(w0.glassAlpha, w1.glassAlpha))
                               + min(charge.glassAlpha, max(w0.glassAlpha, w1.glassAlpha)) * 0.35, 0.0, 0.96);

        float2 totalDisp = charge.dispUV + w0.dispUV + w1.dispUV;
        float refrMask = clamp(max(charge.refrMask, max(w0.refrMask, w1.refrMask)), 0.0, 1.0);

        float3 refractedColor = float3(0.0);
        float refrAlpha = 0.0;
        if (hasBackdrop > 0.5 && refrMask > 0.002) {
            float r = backdrop.sample(backdropSampler, clamp(in.uv - totalDisp * 0.78, 0.001, 0.999)).r;
            float g = backdrop.sample(backdropSampler, clamp(in.uv - totalDisp * 1.04, 0.001, 0.999)).g;
            float b = backdrop.sample(backdropSampler, clamp(in.uv - totalDisp * 1.35, 0.001, 0.999)).b;
            refractedColor = float3(r, g, b) * refrMask;
            refrAlpha = refrMask;
        }

        float3 finalRGB = refractedColor * (1.0 - glassAlpha * 0.30) + totalGlass;
        float finalAlpha = clamp(max(refrAlpha, glassAlpha), 0.0, 0.96);

        return float4(finalRGB * finalAlpha, finalAlpha);
    }
    """
}
