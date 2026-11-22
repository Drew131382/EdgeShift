import Metal

enum RippleShader {
    static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "rippleVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "rippleFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut { float4 position [[position]]; float2 uv; };
    struct RippleUniforms {
        float4 push;
        float4 viewport;
        float4 pushStyle;
        float4 wave0;
        float4 wave0Style;
        float4 wave1;
        float4 wave1Style;
    };

    vertex VertexOut rippleVertex(uint id [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        VertexOut out;
        out.position = float4(p[id], 0, 1);
        out.uv = float2(p[id].x * 0.5 + 0.5, 0.5 - p[id].y * 0.5);
        return out;
    }

    struct Surface {
        float2 displacement;
        float mask;
        float3 reflection;
        float alpha;
        float shadow;
    };

    static inline float3 airdropSpectrum(float angleCoord, float phase) {
        float s1 = 0.5 + 0.5 * sin(angleCoord * 2.2 + phase);
        float s2 = 0.5 + 0.5 * cos(angleCoord * 3.1 - phase);
        float3 cyan   = float3(0.30, 0.88, 1.00);
        float3 azure  = float3(0.36, 0.62, 1.00);
        float3 violet = float3(0.78, 0.48, 1.00);
        float3 rose   = float3(1.00, 0.62, 0.86);
        return mix(mix(cyan, azure, s1), mix(violet, rose, s2), 0.46);
    }

    static Surface liquidSurface(float2 uv, float2 size, float2 origin, float2 normal,
                                 float radius, float presence, float body, float strength,
                                 float phase, bool reduced) {
        Surface s = { float2(0), 0, float3(0), 0, 0 };
        if (presence < 0.001) return s;

        float2 tangent = float2(-normal.y, normal.x);
        float2 delta = (uv - origin) * size;
        float depth = dot(delta, normal);
        float along = dot(delta, tangent);

        float stretch = 1.35;
        float offset = 20.0;
        float2 local = float2(along / stretch, depth + offset);
        float distance = length(local);
        float width = mix(13.0, 25.0, clamp((radius - 44.0) / 360.0, 0.0, 1.0));
        if (reduced) { radius = 50.0; width = 16.0; body = 0.0; }
        if (distance > radius + width * 4.2) return s;

        float effPhase = reduced ? 0.0 : phase;
        float ripple = reduced ? 0.0 : (sin(along * 0.022 + effPhase * 2.0) * 1.6
                                      + sin(along * 0.012 - effPhase) * 1.0)
                                     * smoothstep(10.0, 48.0, distance);
        float diff = distance - radius + ripple;
        float frontWidth = diff > 0.0 ? width * 0.70 : width * 1.35;
        float x = diff / frontWidth;
        float crest = exp(-x * x);
        float slope = -2.0 * x * crest;

        // Continuous outward ripples while pushing (body > 0), seamlessly feeding into
        // multi-ring concentric water waves as the pulse travels (wake = 1 - body).
        float innerRipples = 0.0;
        float innerRippleSlope = 0.0;
        if (!reduced && body > 0.001) {
            float innerWindow = smoothstep(8.0, 26.0, distance)
                              * (1.0 - smoothstep(radius - width * 0.7, radius + width * 0.1, distance));
            float arg = distance * 0.175 - effPhase * 3.0;
            innerRipples = pow(0.5 + 0.5 * sin(arg), 2.2) * innerWindow * body;
            innerRippleSlope = cos(arg) * innerWindow * body;
        }

        float wake = reduced ? 0.0 : 1.0 - body;
        float wake1 = 0.0, wake2 = 0.0, wake3 = 0.0, wake4 = 0.0;
        float wakeSlope1 = 0.0, wakeSlope2 = 0.0, wakeSlope3 = 0.0, wakeSlope4 = 0.0;
        if (wake > 0.001) {
            float spacing = max(28.0, width * 1.95);
            float wWidth = width * 0.92;
            float wx1 = (diff + spacing * 1.00) / wWidth;
            float wx2 = (diff + spacing * 1.95) / (wWidth * 0.96);
            float wx3 = (diff + spacing * 2.85) / (wWidth * 0.92);
            float wx4 = (diff + spacing * 3.70) / (wWidth * 0.88);
            wake1 = exp(-wx1 * wx1) * 0.82 * wake;
            wake2 = exp(-wx2 * wx2) * 0.60 * wake;
            wake3 = exp(-wx3 * wx3) * 0.38 * wake;
            wake4 = exp(-wx4 * wx4) * 0.20 * wake;
            wakeSlope1 = -2.0 * wx1 * wake1;
            wakeSlope2 = -2.0 * wx2 * wake2;
            wakeSlope3 = -2.0 * wx3 * wake3;
            wakeSlope4 = -2.0 * wx4 * wake4;
        }

        float allWaves = crest + wake1 + wake2 + wake3 + wake4 + innerRipples * 0.75;
        float inner = (1.0 - smoothstep(radius * 0.16, radius * 1.02, distance)) * body;
        float fade = 1.0 - smoothstep(radius + width * 2.4, radius + width * 4.2, distance);
        float vis = presence * mix(0.55, 1.0, strength) * fade;

        float2 gradient = distance > 0.001
            ? tangent * (local.x / (stretch * distance)) + normal * (local.y / distance)
            : normal;
        float angleCoord = atan2(local.y, local.x);

        // Smooth, bold optical refraction that visibly bends desktop icons, windows, and text without UV folding.
        float convex = (distance / max(radius, 1.0)) * inner;
        float refraction = slope * 28.0
                         + wakeSlope1 * 22.0
                         + wakeSlope2 * 16.0
                         + wakeSlope3 * 11.0
                         + wakeSlope4 * 6.0
                         + innerRippleSlope * 14.0
                         - convex * 16.0;
        s.displacement = reduced ? float2(0) : gradient * refraction * vis;
        s.mask = reduced ? 0.0 : clamp((allWaves * 1.55 + inner * 0.95) * vis, 0.0, 1.0);

        float outerFringe = max(0.0, -slope)
                          + max(0.0, -wakeSlope1) * 0.75
                          + max(0.0, -wakeSlope2) * 0.55
                          + max(0.0, -wakeSlope3) * 0.35
                          + max(0.0, -innerRippleSlope) * 0.45;
        float innerFringe = max(0.0, slope)
                          + max(0.0, wakeSlope1) * 0.75
                          + max(0.0, wakeSlope2) * 0.55
                          + max(0.0, wakeSlope3) * 0.35
                          + max(0.0, innerRippleSlope) * 0.45;
        float caustic = 0.88 + 0.12 * sin(angleCoord * 6.0 + effPhase * 2.0);

        float3 pearl = float3(0.96, 0.99, 1.00);
        float3 spectrum = airdropSpectrum(angleCoord, effPhase);
        float3 cyanTint = float3(0.28, 0.88, 1.00);
        float3 violetTint = float3(0.82, 0.50, 1.00);

        float crestGlint = (pow(crest, 4.2) * 0.22 + pow(wake1, 3.6) * 0.12 + pow(wake2, 3.6) * 0.08) * caustic;
        float prismGlow = (outerFringe * 0.58 + innerFringe * 0.48) * caustic;
        float bodyTint = clamp(allWaves * 0.14 + inner * 0.10, 0.0, 0.32);

        float3 glassColor = spectrum * (prismGlow * 0.62 + bodyTint * 0.58)
                          + cyanTint * outerFringe * 0.34
                          + violetTint * innerFringe * 0.30
                          + pearl * crestGlint;

        float glassAlpha = clamp((crestGlint * 0.85 + prismGlow * 0.40 + bodyTint * 0.52) * vis, 0.0, 0.68);
        s.alpha = glassAlpha;
        s.reflection = min(glassColor * vis, float3(glassAlpha));
        s.shadow = clamp((max(slope, 0.0) * 0.035 + max(wakeSlope1, 0.0) * 0.025 + max(wakeSlope2, 0.0) * 0.015) * vis, 0.0, 0.045);
        return s;
    }

    fragment float4 rippleFragment(VertexOut in [[stage_in]],
                                   constant RippleUniforms& u [[buffer(0)]],
                                   texture2d<float> backdrop [[texture(0)]],
                                   sampler sampleBackdrop [[sampler(0)]]) {
        float2 size = max(u.viewport.xy, float2(1));
        bool reduced = u.viewport.w > 0.5;
        float radius = 44.0 + 76.0 * clamp(u.push.w, 0.0, 1.0);
        Surface charge = liquidSurface(in.uv, size, u.push.xy, u.pushStyle.xy,
                                       radius, u.push.z, 1.0, u.push.w, u.pushStyle.z, reduced);
        Surface a = liquidSurface(in.uv, size, u.wave0.xy, u.wave0Style.xy,
                                  u.wave0.z, u.wave0.w, u.wave0Style.z, u.wave0Style.w,
                                  u.pushStyle.z, reduced);
        Surface b = liquidSurface(in.uv, size, u.wave1.xy, u.wave1Style.xy,
                                  u.wave1.z, u.wave1.w, u.wave1Style.z, u.wave1Style.w,
                                  u.pushStyle.z, reduced);

        float mask = max(charge.mask, max(a.mask, b.mask)) * u.viewport.z;
        float reflectionAlpha = 1.0 - (1.0 - charge.alpha) * (1.0 - a.alpha) * (1.0 - b.alpha);
        if (mask < 0.001 && reflectionAlpha < 0.001) return float4(0);

        float3 reflection = charge.reflection + a.reflection * (1.0 - charge.alpha)
                          + b.reflection * (1.0 - charge.alpha) * (1.0 - a.alpha);

        float3 transmitted = float3(0);
        if (mask > 0.001) {
            float2 displacement = charge.displacement + a.displacement + b.displacement;
            float2 offsetUV = displacement / size;
            float2 ortho = float2(-offsetUV.y, offsetUV.x) * 0.14;
            float2 texel = 0.5 / float2(backdrop.get_width(), backdrop.get_height());

            // Wide 5-tap spectral chromatic dispersion for vivid optical glass color splitting.
            float3 sR = backdrop.sample(sampleBackdrop, clamp(in.uv - offsetUV * 0.38 + ortho, texel, 1.0 - texel)).rgb;
            float3 sY = backdrop.sample(sampleBackdrop, clamp(in.uv - offsetUV * 0.70 - ortho, texel, 1.0 - texel)).rgb;
            float3 sG = backdrop.sample(sampleBackdrop, clamp(in.uv - offsetUV * 1.02,         texel, 1.0 - texel)).rgb;
            float3 sC = backdrop.sample(sampleBackdrop, clamp(in.uv - offsetUV * 1.38 + ortho, texel, 1.0 - texel)).rgb;
            float3 sB = backdrop.sample(sampleBackdrop, clamp(in.uv - offsetUV * 1.76 - ortho, texel, 1.0 - texel)).rgb;

            float redOut = sR.r * 0.74 + sY.r * 0.26;
            float greenOut = sY.g * 0.24 + sG.g * 0.52 + sC.g * 0.24;
            float blueOut = sC.b * 0.26 + sB.b * 0.74;

            float shadow = max(charge.shadow, max(a.shadow, b.shadow));
            transmitted = float3(redOut, greenOut, blueOut) * (1.0 - shadow);
        }

        float alpha = mask + reflectionAlpha * (1.0 - mask);
        float3 rgb = transmitted * mask * (1.0 - reflectionAlpha) + reflection;
        return float4(clamp(rgb, float3(0), float3(alpha)), alpha);
    }
    """
}
