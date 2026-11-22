import AppKit
import Metal

// Runs the production shader on the GPU, without screen capture permission or
// changing the user's display layout. Optional output: --preview /absolute/path.
@main
struct RippleChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }

    static func backdrop(device: MTLDevice, width: Int, height: Int, white: Bool = false,
                         blue: Bool = false) -> MTLTexture {
        let texture = device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false))!
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let grid = x % 32 < 2 || y % 32 < 2
                pixels[index] = white ? 255 : (blue ? 230 : (grid ? 50 : 100))
                pixels[index + 1] = white ? 255 : (grid ? 110 : 180)
                pixels[index + 2] = white ? 255 : (blue ? 70 : (grid ? 210 : 240))
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: &pixels, bytesPerRow: width * 4)
        return texture
    }

    static func render(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState,
                       uniforms: RippleUniforms, backdrop: MTLTexture,
                       drawableSize: CGSize? = nil, clipped: Bool = true) throws -> [UInt8] {
        let size = drawableSize ?? CGSize(width: CGFloat(uniforms.viewport.x), height: CGFloat(uniforms.viewport.y))
        let width = Int(size.width), height = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let output = device.makeTexture(descriptor: descriptor)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let command = queue.makeCommandBuffer()!
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        var data = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&data, length: MemoryLayout<RippleUniforms>.stride, index: 0)
        encoder.setFragmentTexture(backdrop, index: 0)
        encoder.setFragmentSamplerState(device.makeSamplerState(descriptor: sampler), index: 0)
        if clipped {
            if let region = uniforms.pixelBounds(drawableSize: size) {
                encoder.setScissorRect(MTLScissorRect(x: Int(region.minX), y: Int(region.minY),
                                                    width: Int(region.width), height: Int(region.height)))
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        } else {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        output.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    static func checkPremultiplied(_ pixels: [UInt8]) {
        for i in stride(from: 0, to: pixels.count, by: 4) {
            require(Int(pixels[i]) <= Int(pixels[i + 3]) + 1 &&
                    Int(pixels[i + 1]) <= Int(pixels[i + 3]) + 1 &&
                    Int(pixels[i + 2]) <= Int(pixels[i + 3]) + 1, "Invalid premultiplied edge")
        }
    }

    static func wave(origin: SIMD2<Float>, normal: SIMD2<Float>) -> RippleWave {
        RippleWave(origin: origin, normal: normal, startTime: 0, startRadius: 120,
                   endRadius: 300, presence: 1, strength: 1)
    }

    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "RippleChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal device required"])
        }
        let pipeline = try RippleShader.makePipeline(device: device)
        require(MemoryLayout<RippleUniforms>.stride == 112, "Swift/Metal uniform layout mismatch")
        var u = RippleUniforms()
        u.viewport = SIMD4(512, 512, 1, 0)
        let grid = backdrop(device: device, width: 512, height: 512)
        let white = backdrop(device: device, width: 512, height: 512, white: true)
        let blue = backdrop(device: device, width: 512, height: 512, blue: true)
        let empty = try render(device: device, queue: queue, pipeline: pipeline, uniforms: u, backdrop: grid)
        require(empty.allSatisfy { $0 == 0 }, "Inactive overlay is not transparent")

        let edges: [(Side, SIMD2<Float>, Int, Int)] = [
            (.left, SIMD2(0, 0.5), 40, 256), (.right, SIMD2(1, 0.5), 471, 256),
            (.top, SIMD2(0.5, 0), 256, 40), (.bottom, SIMD2(0.5, 1), 256, 471)
        ]
        for (edge, origin, nearX, nearY) in edges {
            let normal = RippleMotion.normal(for: edge)
            u.push = SIMD4(origin.x, origin.y, 1, 1)
            u.pushStyle = SIMD4(normal.x, normal.y, 0, 0)
            let charge = try render(device: device, queue: queue, pipeline: pipeline, uniforms: u, backdrop: grid)
            let fullCharge = try render(device: device, queue: queue, pipeline: pipeline, uniforms: u, backdrop: grid, clipped: false)
            require(charge == fullCharge, "Scissor clips the charging surface at \(edge)")
            checkPremultiplied(charge)
            require(charge[(nearY * 512 + nearX) * 4 + 3] > 80, "Missing lens at \(edge)")
            require(charge[((511 - nearY) * 512 + 511 - nearX) * 4 + 3] == 0, "Effect reaches opposite edge")

            var released = u
            released.push = .zero
            let start = wave(origin: origin, normal: normal).sample(at: 0)!
            released.wave0 = start.data
            released.wave0Style = start.style
            let first = try render(device: device, queue: queue, pipeline: pipeline, uniforms: released, backdrop: grid)
            require(charge == first, "Charging surface jumps on release at \(edge)")
            for t in [0.05, 0.2, 0.5, 0.679] {
                let sample = wave(origin: origin, normal: normal).sample(at: t)!
                released.wave0 = sample.data
                released.wave0Style = sample.style
                let clippedWave = try render(device: device, queue: queue, pipeline: pipeline,
                                             uniforms: released, backdrop: grid)
                let fullWave = try render(device: device, queue: queue, pipeline: pipeline,
                                          uniforms: released, backdrop: grid, clipped: false)
                require(clippedWave == fullWave, "Scissor clips a travelling wave at \(edge)")
                checkPremultiplied(clippedWave)
            }
        }
        let pulse = wave(origin: SIMD2(0, 0.5), normal: SIMD2(1, 0))
        var previous: Float = 0
        for step in 0..<68 {
            let sample = pulse.sample(at: Double(step) / 100)!
            require(sample.data.z >= previous, "Wave reverses its travel")
            previous = sample.data.z
        }
        require(pulse.sample(at: RippleMotion.waveDuration) == nil, "Wave does not finish")
        let firstFrame = pulse.sample(at: 1.0 / 120)!
        require(firstFrame.data.z - pulse.startRadius < 1.5, "Wave jumps forward on its first 120Hz frame")
        require(1 - firstFrame.style.z < 0.01, "Trailing ripples pop into the first release frame")
        var movingPulse = pulse
        movingPulse.initialVelocity = 40
        let derivative = (movingPulse.sample(at: 0.0001)!.data.z - movingPulse.startRadius) / 0.0001
        require(abs(derivative - 40) < 2, "Release does not preserve charging velocity")
        var clock = RippleFrameClock()
        require(clock.advance(to: 10, frameInterval: 1.0 / 165) == 0, "Frame clock starts with a jump")
        _ = clock.advance(to: 10 + 1.0 / 165, frameInterval: 1.0 / 165)
        let beforePause = clock.time
        _ = clock.advance(to: 12, frameInterval: 1.0 / 165)
        require(clock.time - beforePause <= 1.0 / 60 + 0.000001, "Missed presentation skips animation time")
        require(pulse.sample(at: clock.time) != nil, "Display stall consumes the entire wave")
        clock.reset()
        require(clock.time == 0 && clock.lastPresentation == nil, "Frame clock does not reset")
        require(RippleMotion.easeOut(0) == 0 && RippleMotion.easeOut(1) == 1, "Invalid easing endpoints")

        u.push = SIMD4(0, 0.5, 1, 1)
        u.pushStyle = SIMD4(1, 0, 0, 0)
        let onWhite = try render(device: device, queue: queue, pipeline: pipeline, uniforms: u, backdrop: white)
        for i in stride(from: 0, to: onWhite.count, by: 4) {
            for channel in 0..<3 {
                let composite = Int(onWhite[i + channel]) + 255 - Int(onWhite[i + 3])
                require(composite >= 215, "Dark alpha halo on a white desktop")
            }
        }
        let redFrame = try render(device: device, queue: queue, pipeline: pipeline, uniforms: u, backdrop: grid)
        let blueFrame = try render(device: device, queue: queue, pipeline: pipeline, uniforms: u, backdrop: blue)
        require(redFrame != blueFrame, "Shader does not sample changing desktop textures")
        u.viewport.z = 0
        let fallback = try render(device: device, queue: queue, pipeline: pipeline, uniforms: u, backdrop: grid)
        checkPremultiplied(fallback)
        require(fallback.contains { $0 > 0 }, "No permission fallback is invisible")
        u.viewport.z = 1
        u.viewport.w = 1
        let reducedA = try render(device: device, queue: queue, pipeline: pipeline, uniforms: u, backdrop: grid)
        u.pushStyle.z = 99
        let reducedB = try render(device: device, queue: queue, pipeline: pipeline, uniforms: u, backdrop: blue)
        require(reducedA == reducedB, "Reduced motion still warps or oscillates")
        for size in [CGSize(width: 1024, height: 1024), CGSize(width: 512, height: 1280)] {
            var portrait = RippleUniforms()
            portrait.viewport = SIMD4(Float(size.width / 2), Float(size.height / 2), 1, 0)
            portrait.push = SIMD4(0, 0.9, 1, 1)
            portrait.pushStyle = SIMD4(1, 0, 0, 0)
            let partial = try render(device: device, queue: queue, pipeline: pipeline, uniforms: portrait,
                                     backdrop: grid, drawableSize: size)
            let full = try render(device: device, queue: queue, pipeline: pipeline, uniforms: portrait,
                                  backdrop: grid, drawableSize: size, clipped: false)
            require(partial == full, "Scissor clips Retina/portrait output")
        }
        print("PASS: Metal shader, 4 directions, continuous release and velocity, frame clock across display stalls, wave lifetime, exact scissor output including Retina/portrait, alpha halos, changing textures, fallback, reduced motion")

        if let flag = CommandLine.arguments.firstIndex(of: "--preview"), flag + 1 < CommandLine.arguments.count {
            try preview(device: device, queue: queue, pipeline: pipeline,
                        directory: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }
    }

    static func preview(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState,
                        directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = 800, height = 500
        let bg = backdrop(device: device, width: width, height: height)
        var source = [UInt8](repeating: 0, count: width * height * 4)
        bg.getBytes(&source, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var u = RippleUniforms()
        u.viewport = SIMD4(Float(width), Float(height), 1, 0)
        u.pushStyle = SIMD4(1, 0, 0, 0)
        let pulse = RippleWave(origin: SIMD2(0, 0.5), normal: SIMD2(1, 0), startTime: 1.2,
                               startRadius: 120, endRadius: 300, presence: 1, strength: 1)
        for step in 0..<66 {
            let time = Double(step) / 30
            u.pushStyle.z = Float(time) * 1.4
            u.push = .zero
            u.wave0 = SIMD4(0, 0, 1, 0)
            if time < 1.2 {
                u.push = SIMD4(0, 0.5, RippleMotion.easeOut(Float(time / 0.2)), Float(time / 1.2))
            } else if let sample = pulse.sample(at: time) {
                u.wave0 = sample.data
                u.wave0Style = sample.style
            }
            let overlay = try render(device: device, queue: queue, pipeline: pipeline, uniforms: u, backdrop: bg)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
            let out = bitmap.bitmapData!
            for i in stride(from: 0, to: source.count, by: 4) {
                let alpha = Float(overlay[i + 3]) / 255
                for channel in 0..<3 {
                    // Bitmap is RGBA; Metal texture readback is BGRA.
                    let c = 2 - channel
                    out[i + channel] = UInt8(min(255, Float(overlay[i + c]) + Float(source[i + c]) * (1 - alpha)))
                }
                out[i + 3] = 255
            }
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: directory.appendingPathComponent(String(format: "%03d.png", step)))
        }
        print("Rendered production shader preview frames to \(directory.path)")
    }
}
