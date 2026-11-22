import AppKit
import CoreGraphics
import Metal
import MetalKit
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

private struct RippleUniforms {
    var pushData: SIMD4<Float>   // xy = origin, z = presence, w = strength
    var meta: SIMD4<Float>       // x = pushPhase, y = aspect, z = hasBackdrop, w = wobblePhase
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
    private var pushPhase: Float = 0
    private var pushWobblePhase: Float = 0

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
        if mtkView?.isPaused != false { mtkView?.isPaused = false }
        if window?.isVisible != true { window?.orderFrontRegardless() }

        refreshBackdropIfAuthorized(displayID: displayID, device: device, force: forceBackdropRefresh)
    }

    private func refreshBackdropIfAuthorized(displayID: CGDirectDisplayID, device: MTLDevice, force: Bool) {
        guard #available(macOS 14.0, *), CGPreflightScreenCaptureAccess() else { return }
        if !force, backdropDisplayID == displayID, backdropTexture != nil {
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

        // Integrate phase monotonically so accelerating speed never causes phase jumps or strobing.
        let ringSpeed: Float = 2.6 + 1.8 * pushStrength
        pushPhase = (pushPhase + dt * ringSpeed).truncatingRemainder(dividingBy: Float.pi * 2.0)
        pushWobblePhase = (pushWobblePhase + dt * 2.2).truncatingRemainder(dividingBy: Float.pi * 2.0)

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
            pushPhase = 0
            pushWobblePhase = 0
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
            meta: SIMD4<Float>(pushPhase, aspect, backdropTexture != nil ? 1.0 : 0.0, pushWobblePhase),
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
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
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
        float4 meta;     // x = pushPhase, y = aspect, z = hasBackdrop, w = wobblePhase
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

    static inline float3 airdropSpectrum(float angle, float t) {
        // Signature iOS AirDrop / NameDrop iridescent palette: ice cyan -> azure -> violet -> soft rose.
        float s = 0.5 + 0.5 * sin(angle * 2.0 + t * 2.2);
        float s2 = 0.5 + 0.5 * cos(angle * 3.0 - t * 1.6);
        float3 cyan   = float3(0.32, 0.86, 1.00);
        float3 azure  = float3(0.38, 0.60, 1.00);
        float3 violet = float3(0.76, 0.50, 1.00);
        float3 rose   = float3(1.00, 0.62, 0.84);
        return mix(mix(cyan, azure, s), mix(violet, rose, s2), 0.45);
    }

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

        // Snappy iOS spring-like launch that glides smoothly into distance.
        float eased = 1.0 - pow(1.0 - t, 3.8);
        float2 delta = float2((uv.x - wave.x) * aspect, uv.y - wave.y);
        float dist = length(delta);
        float maxR = wave.w;
        if (dist > maxR * 1.08) { return res; }
        float2 dir = dist > 1e-5 ? delta / dist : float2(0.0, 0.0);
        float angle = atan2(delta.y, delta.x);

        // Subtle fluid surface tension undulation (never jagged).
        float fluidWobble = (sin(angle * 3.0 + t * 4.0) * 0.004
                           + sin(angle * 5.0 - t * 3.2) * 0.0022)
                          * smoothstep(0.0, 0.05, dist);
        float d = dist + fluidWobble * smoothstep(0.0, 0.25, t);

        // Single broad, glossy AirDrop liquid shockwave + subtle soft wake (no bullseye stripes).
        float r1 = mix(0.02, maxR, eased);
        float w1Front = mix(0.018, 0.036, eased);
        float w1Back  = mix(0.042, 0.092, eased);
        float w1 = fluidBand(d, r1, w1Front, w1Back);

        float r2 = r1 * 0.72;
        float w2 = fluidBand(d, r2, w1Front * 0.9, w1Back * 0.9) * 0.22 * smoothstep(0.06, 0.28, t);

        float combinedWave = w1 + w2;

        float diff1 = d - r1;
        float activeW1 = diff1 >= 0.0 ? w1Front : w1Back;
        float slope1 = -2.0 * diff1 / max(activeW1 * activeW1, 0.0001) * w1;

        float diff2 = d - r2;
        float activeW2 = diff2 >= 0.0 ? w1Front * 0.9 : w1Back * 0.9;
        float slope2 = -2.0 * diff2 / max(activeW2 * activeW2, 0.0001) * w2;

        float slope = clamp((slope1 + slope2 * 0.45) * 0.026, -1.0, 1.0);

        float timeEnvelope = smoothstep(0.0, 0.07, t) * (1.0 - smoothstep(0.35, 1.0, t));
        float spatialDecay = exp(-pow(d / max(maxR * 0.70, 0.01), 2.0) * 1.85)
                           * (1.0 - smoothstep(maxR * 0.64, maxR, d));
        float envelope = timeEnvelope * spatialDecay;

        float3 spectrum = airdropSpectrum(angle, t * 2.5);
        float3 pearlSheen = float3(0.95, 0.98, 1.0);

        float outerFringe = max(0.0, -slope);
        float innerFringe = max(0.0, slope);

        // Very restrained specular glint; iridescent liquid refraction carries the visual.
        float crestGlint = pow(clamp(w1, 0.0, 1.0), 4.4) * 0.28;
        float prismRim = (outerFringe * 0.92 + innerFringe * 0.72) * (0.85 + 0.15 * sin(angle * 7.0 + t * 5.0));
        float softBody = clamp(w1 * 0.42 + w2 * 0.28, 0.0, 1.0);

        res.glassColor = (spectrum * (prismRim * 0.85 + softBody * 0.28)
                        + pearlSheen * crestGlint) * envelope;

        res.glassAlpha = clamp((crestGlint * 0.88 + prismRim * 0.50 + softBody * 0.20) * envelope, 0.0, 0.78);

        float dispStrength = (0.11 * (1.0 - 0.25 * eased)) * envelope;
        float2 dirUV = float2(dir.x / max(aspect, 0.001), dir.y);
        res.dispUV = dirUV * slope * dispStrength;
        res.refrMask = clamp(combinedWave * envelope * 1.55, 0.0, 1.0);
        return res;
    }

    static inline RippleContribution evalChargingPush(
        float2 uv,
        float4 pushData,
        float pushPhase,
        float wobblePhase,
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
        float intensity = mix(0.45, 1.0, pow(strength, 0.80));

        float2 delta = float2((uv.x - pushData.x) * aspect, uv.y - pushData.y);
        float dist = length(delta);

        // iPhone AirDrop meniscus bulge: a single smooth liquid lens swelling from the edge,
        // with a soft breathing ripple (NO rapid bullseye sonar rings).
        float breathe = 1.0 + 0.055 * sin(pushPhase);
        float lensRadius = mix(0.062, 0.175, strength) * breathe;
        float maxReach = lensRadius * 1.65;
        if (dist > maxReach) { return res; }

        float2 dir = dist > 1e-5 ? delta / dist : float2(0.0, 0.0);
        float angle = atan2(delta.y, delta.x);

        float wobble = (sin(angle * 3.0 + wobblePhase) * 0.0035
                      + sin(angle * 5.0 - wobblePhase * 0.7) * 0.0020)
                     * smoothstep(0.0, 0.04, dist);
        float d = dist + wobble * (0.4 + 0.6 * strength);

        // Smooth lens profile: convex magnification inside lensRadius, curved glass rim right at lensRadius.
        float rimBand = fluidBand(d, lensRadius, lensRadius * 0.24, lensRadius * 0.42);
        float innerLens = 1.0 - smoothstep(lensRadius * 0.35, lensRadius * 1.25, d);
        float spatialFade = 1.0 - smoothstep(lensRadius * 1.05, maxReach, d);

        float diff = d - lensRadius;
        float activeW = diff >= 0.0 ? lensRadius * 0.24 : lensRadius * 0.42;
        float rimSlope = clamp(-2.0 * diff / max(activeW * activeW, 0.0001) * rimBand * 0.016, -1.0, 1.0);

        // Convex water-drop lens warp inside the bulge + strong refractive rim.
        float lensWarp = -smoothstep(0.0, lensRadius, d) * innerLens * 0.45 + rimSlope;

        float3 spectrum = airdropSpectrum(angle, wobblePhase);
        float3 pearlSheen = float3(0.95, 0.98, 1.0);

        float vis = presence * intensity * spatialFade;
        float crestGlint = pow(clamp(rimBand, 0.0, 1.0), 4.0) * 0.16;
        float rimPrism = (abs(rimSlope) * 0.70 + rimBand * 0.28);

        res.glassColor = (spectrum * (rimPrism * 0.68 + innerLens * 0.10)
                        + pearlSheen * crestGlint) * vis;

        res.glassAlpha = clamp((crestGlint * 0.75 + rimPrism * 0.38 + innerLens * 0.08) * vis, 0.0, 0.68);

        float2 dirUV = float2(dir.x / max(aspect, 0.001), dir.y);
        res.dispUV = dirUV * lensWarp * (0.055 + 0.040 * strength) * vis;
        res.refrMask = clamp((innerLens * 0.85 + rimBand * 1.15) * vis, 0.0, 1.0);
        return res;
    }

    fragment float4 rippleFragment(
        VertexOut in [[stage_in]],
        constant RippleUniforms& u [[buffer(0)]],
        texture2d<float> backdrop [[texture(0)]],
        sampler backdropSampler [[sampler(0)]]
    ) {
        float pushPhase = u.meta.x;
        float aspect = u.meta.y;
        float hasBackdrop = u.meta.z;
        float wobblePhase = u.meta.w;

        RippleContribution charge = evalChargingPush(in.uv, u.pushData, pushPhase, wobblePhase, aspect);
        RippleContribution w0 = evalHighlightWave(in.uv, u.wave0, aspect);
        RippleContribution w1 = evalHighlightWave(in.uv, u.wave1, aspect);

        float3 totalGlass = charge.glassColor + w0.glassColor + w1.glassColor;
        float glassAlpha = clamp(max(charge.glassAlpha, max(w0.glassAlpha, w1.glassAlpha))
                               + min(charge.glassAlpha, max(w0.glassAlpha, w1.glassAlpha)) * 0.30, 0.0, 0.78);

        float2 totalDisp = charge.dispUV + w0.dispUV + w1.dispUV;
        float refrMask = clamp(max(charge.refrMask, max(w0.refrMask, w1.refrMask)), 0.0, 1.0);

        float3 refractedColor = float3(0.0);
        float refrAlpha = 0.0;
        if (hasBackdrop > 0.5 && refrMask > 0.002) {
            // Soft liquid-glass micro-blur + 5-tap chromatic dispersion along the refraction vector.
            float2 ortho = float2(-totalDisp.y, totalDisp.x) * 0.16;
            float3 sR = backdrop.sample(backdropSampler, clamp(in.uv - totalDisp * 0.50 + ortho, 0.001, 0.999)).rgb;
            float3 sY = backdrop.sample(backdropSampler, clamp(in.uv - totalDisp * 0.78 - ortho, 0.001, 0.999)).rgb;
            float3 sG = backdrop.sample(backdropSampler, clamp(in.uv - totalDisp * 1.04, 0.001, 0.999)).rgb;
            float3 sC = backdrop.sample(backdropSampler, clamp(in.uv - totalDisp * 1.34 + ortho, 0.001, 0.999)).rgb;
            float3 sB = backdrop.sample(backdropSampler, clamp(in.uv - totalDisp * 1.68 - ortho, 0.001, 0.999)).rgb;

            float r = sR.r * 0.72 + sY.r * 0.28;
            float g = sY.g * 0.24 + sG.g * 0.52 + sC.g * 0.24;
            float b = sC.b * 0.28 + sB.b * 0.72;
            refractedColor = float3(r, g, b) * refrMask;
            refrAlpha = refrMask;
        }

        float3 finalRGB = refractedColor * (1.0 - glassAlpha * 0.20) + totalGlass;
        float finalAlpha = clamp(max(refrAlpha, glassAlpha), 0.0, 0.94);

        return float4(finalRGB * finalAlpha, finalAlpha);
    }
    """
}
