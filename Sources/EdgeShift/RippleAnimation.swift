import CoreGraphics
import Foundation
import simd

// Advance only when a drawable can actually be rendered. A display transaction
// can stop callbacks briefly; that gap must not skip most of the visible wave.
struct RippleFrameClock {
    private(set) var time: TimeInterval = 0
    private(set) var lastPresentation: TimeInterval?

    mutating func advance(to hostTime: TimeInterval, frameInterval: TimeInterval) -> Float {
        let elapsed = lastPresentation.map { max(0, hostTime - $0) } ?? 0
        lastPresentation = hostTime
        let step = min(elapsed, max(frameInterval, 1.0 / 60))
        time += step
        return Float(step)
    }

    mutating func reset() { self = RippleFrameClock() }
}

// Shared by the window renderer and the offscreen Metal checks.
struct RippleUniforms {
    var push: SIMD4<Float> = .zero                 // origin.xy, presence, strength
    var viewport: SIMD4<Float> = .zero             // logical size.xy, backdrop mix, reduced motion
    var pushStyle: SIMD4<Float> = .zero            // inward normal.xy, surface phase, unused
    var wave0 = SIMD4<Float>(0, 0, 1, 0)            // origin.xy, radius in points, presence
    var wave0Style: SIMD4<Float> = .zero           // inward normal.xy, convex body, strength
    var wave1 = SIMD4<Float>(0, 0, 1, 0)
    var wave1Style: SIMD4<Float> = .zero

    // Conservative screen-space bounds for all nontransparent shader output.
    // The 128pt guard covers the widest rim (25 * 4.2), surface tension and
    // sampling precision. The render pass still clears the entire drawable.
    func pixelBounds(drawableSize: CGSize) -> CGRect? {
        guard viewport.x > 0, viewport.y > 0, drawableSize.width > 0, drawableSize.height > 0 else { return nil }
        let logicalSize = SIMD2(viewport.x, viewport.y)
        var bounds = CGRect.null
        func include(_ data: SIMD4<Float>, style: SIMD4<Float>, charging: Bool) {
            let visible = charging ? data.z : data.w
            guard visible >= 0.001 else { return }
            let direction = SIMD2(style.x, style.y)
            let tangent = SIMD2(-direction.y, direction.x)
            let radius = viewport.w > 0.5 ? 50 : (charging ? RippleMotion.radius(strength: data.w) : data.z)
            let extent = max(radius, 0) + 128
            let center = SIMD2(data.x, data.y) * logicalSize - direction * 20
            let halfSize = simd_abs(direction) * extent + simd_abs(tangent) * (extent * 1.5)
            bounds = bounds.union(CGRect(x: CGFloat(center.x - halfSize.x), y: CGFloat(center.y - halfSize.y),
                                         width: CGFloat(halfSize.x * 2), height: CGFloat(halfSize.y * 2)))
        }
        include(push, style: pushStyle, charging: true)
        include(wave0, style: wave0Style, charging: false)
        include(wave1, style: wave1Style, charging: false)
        guard !bounds.isNull else { return nil }
        let scaled = CGRect(x: bounds.minX * drawableSize.width / CGFloat(viewport.x),
                            y: bounds.minY * drawableSize.height / CGFloat(viewport.y),
                            width: bounds.width * drawableSize.width / CGFloat(viewport.x),
                            height: bounds.height * drawableSize.height / CGFloat(viewport.y)).integral
        let clipped = scaled.intersection(CGRect(origin: .zero, size: drawableSize))
        return clipped.isEmpty || clipped.isNull ? nil : clipped
    }
}

enum RippleMotion {
    // Keep the existing propagation duration; this is a travelling liquid surface,
    // rather than a delay on the actual display configuration change.
    static let waveDuration: TimeInterval = 0.68

    static func normal(for edge: Side) -> SIMD2<Float> {
        switch edge {
        case .left: return SIMD2(1, 0)
        case .right: return SIMD2(-1, 0)
        case .top: return SIMD2(0, 1)
        case .bottom: return SIMD2(0, -1)
        }
    }

    static func radius(strength: Float) -> Float { 44 + 76 * min(max(strength, 0), 1) }

    // cubic-bezier(0.23, 1, 0.32, 1): solve x first so it is frame-rate independent.
    static func easeOut(_ progress: Float) -> Float {
        let x = min(max(progress, 0), 1)
        if x == 0 || x == 1 { return x }
        var lo: Float = 0
        var hi: Float = 1
        for _ in 0..<16 {
            let t = (lo + hi) * 0.5
            let s = 1 - t
            let bx = 3 * s * s * t * 0.23 + 3 * s * t * t * 0.32 + t * t * t
            if bx < x { lo = t } else { hi = t }
        }
        return 1 - pow(1 - (lo + hi) * 0.5, 3)
    }
}

struct RippleWave {
    let origin: SIMD2<Float>
    let normal: SIMD2<Float>
    let startTime: TimeInterval
    let startRadius: Float
    let endRadius: Float
    let presence: Float
    let strength: Float
    var initialVelocity: Float = 0 // points/sec carried over from the charging lens

    func sample(at time: TimeInterval) -> (data: SIMD4<Float>, style: SIMD4<Float>)? {
        let progress = Float(max(0, time - startTime) / RippleMotion.waveDuration)
        guard progress < 1 else { return nil }
        let elapsed = Float(max(0, time - startTime))
        // Critically damped spring: mass 1, stiffness 100, damping 2*sqrt(100).
        // Carry the charging velocity into release instead of instantly jumping
        // to the steep initial velocity of a strong ease-out curve.
        let frequency: Float = 10
        let decay = exp(-frequency * elapsed)
        let distance = max(0, endRadius - startRadius)
        let velocity = min(max(initialVelocity, 0), distance * frequency)
        let radius = endRadius - (distance + (distance * frequency - velocity) * elapsed) * decay
        // The first frame is exactly the charging surface. Its convex interior
        // drains into the moving crest while the broad wake dissolves behind it.
        let body = (1 + frequency * elapsed) * decay
        let fade = min(max((progress - 0.08) / 0.92, 0), 1)
        let opacity = presence * (1 - fade * fade * (3 - 2 * fade))
        return (SIMD4(origin.x, origin.y, radius, opacity),
                SIMD4(normal.x, normal.y, body, strength))
    }
}
