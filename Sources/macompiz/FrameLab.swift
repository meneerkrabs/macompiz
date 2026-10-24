import AppKit
import Metal
import simd

// Offscreen frame renderer for the README GIFs. Runs the exact same shader
// pipelines as the live app, but into an off-screen texture read back to PNG —
// no on-screen windows, no screen capture, no user content. One PNG sequence per
// effect; ffmpeg turns each into a GIF (see scripts/make-gifs.sh).
enum FrameLab {
    static let W = 900, H = 620

    static func renderAll(to dir: String) {
        let fm = FileManager.default
        let note = GPU.shared.texture(from: NoteRenderer.image(
            title: "macompiz",
            body: "# MacOS Compiz?\n\nHello world,\n\nDrag me to **wobble**.\nClick for `water`.\nClose me to **burn**.",
            size: CGSize(width: W, height: H)), pixelSize: CGSize(width: W, height: H))

        let blue = MTLClearColor(red: 0.13, green: 0.44, blue: 0.80, alpha: 1)

        func write(_ name: String, _ frames: [CGImage]) {
            let d = "\(dir)/\(name)"
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
            for (i, img) in frames.enumerated() {
                GPU.savePNG(img, to: String(format: "%@/f%03d.png", d, i))
            }
            print("  \(name): \(frames.count) frames")
        }

        print("rendering frames to \(dir)")
        write("wobbly", wobbleSimFrames(note, blue))
        write("water", windowFrames(note, blue, count: 54) { t, u in
            u.rippleCount = 8                        // staggered ripples for life
            u.ripples.0 = SIMD4(0.35, 0.35, 0.00, 1)
            u.ripples.1 = SIMD4(0.68, 0.50, 0.45, 1)
            u.ripples.2 = SIMD4(0.50, 0.70, 0.95, 1)
            u.time = t
        })
        for (name, kind, dur) in [("burn", 1, 1.35), ("glide", 2, 0.9),
                                  ("explode", 3, 0.9), ("magic-lamp", 4, 0.95),
                                  ("sidekick", 5, 0.95), ("curved-fold", 6, 0.9)] {
            write(name, windowFrames(note, blue, count: 44) { t, u in
                u.animKind = Float(kind)
                u.anim = min(1, Float(t) / Float(dur))
                u.time = t
            })
        }
        write("cube", cubeFrames(note))
        print("done")
    }

    // MARK: spring-lattice wobble (Compiz-style)
    private static func wobbleSimFrames(_ tex: MTLTexture, _ clear: MTLClearColor) -> [CGImage] {
        let sim = WobbleSim()
        sim.grab = SIMD2(0.5, 0.06)
        let lat = GPU.shared.device.makeBuffer(
            length: WobbleSim.N * WobbleSim.N * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared)!
        let target = makeTarget(W, H)
        var u = WindowUniforms()
        u.aspect = Float(W) / Float(H); u.grabActive = 1; u.animKind = 0
        var out: [CGImage] = []
        for i in 0..<66 {
            if i < 7 { sim.tug(SIMD2(0.024, 0.006)) }   // yank right, then let go
            sim.step(1.0 / 30)
            _ = sim.disp.withUnsafeBytes { memcpy(lat.contents(), $0.baseAddress!, $0.count) }
            u.time = Float(i) / 30
            if let img = renderWobble(target, tex, &u, lat, clear) { out.append(img) }
        }
        return out
    }

    private static func renderWobble(_ target: MTLTexture, _ tex: MTLTexture,
                                     _ u: inout WindowUniforms, _ lat: MTLBuffer,
                                     _ clear: MTLClearColor) -> CGImage? {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clear
        rpd.colorAttachments[0].storeAction = .store
        guard let cmd = GPU.shared.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        enc.setRenderPipelineState(GPU.shared.wobblePipeline)
        enc.setVertexBuffer(GPU.shared.gridBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(lat, offset: 0, index: 2)
        withUnsafeBytes(of: &u) {
            enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
            enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: GPU.shared.gridCount)
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        return readback(target)
    }

    // MARK: window pipeline frames
    private static func windowFrames(_ tex: MTLTexture, _ clear: MTLClearColor,
                                     count: Int,
                                     _ setup: (Float, inout WindowUniforms) -> Void) -> [CGImage] {
        let target = makeTarget(W, H)
        var out: [CGImage] = []
        let fps: Float = 30
        for i in 0..<count {
            var u = WindowUniforms()
            u.aspect = Float(W) / Float(H)
            setup(Float(i) / fps, &u)
            if let img = renderWindow(target, tex, &u, clear) { out.append(img) }
        }
        return out
    }

    private static func renderWindow(_ target: MTLTexture, _ tex: MTLTexture,
                                     _ u: inout WindowUniforms, _ clear: MTLClearColor) -> CGImage? {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clear
        rpd.colorAttachments[0].storeAction = .store
        guard let cmd = GPU.shared.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        enc.setRenderPipelineState(GPU.shared.windowPipeline)
        enc.setVertexBuffer(GPU.shared.gridBuffer, offset: 0, index: 0)
        withUnsafeBytes(of: &u) {
            enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
            enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: GPU.shared.gridCount)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return readback(target)
    }

    // MARK: cube pipeline frames
    private static func cubeFrames(_ note: MTLTexture) -> [CGImage] {
        let faceA = SpaceFactory.space(label: "MacOS Compiz?",
            body: "Drag to wobble, click for water.",
            hueTop: NSColor(srgbRed: 0.76, green: 0.87, blue: 0.98, alpha: 1),
            hueBottom: NSColor(srgbRed: 0.10, green: 0.42, blue: 0.78, alpha: 1),
            pixelSize: CGSize(width: W, height: H))
        let faceB = SpaceFactory.space(label: "3D Spaces?",
            body: "Switch spaces via cube rotation.",
            hueTop: NSColor(srgbRed: 0.98, green: 0.90, blue: 0.75, alpha: 1),
            hueBottom: NSColor(srgbRed: 0.20, green: 0.55, blue: 0.70, alpha: 1),
            pixelSize: CGSize(width: W, height: H))
        _ = note

        let target = makeTarget(W, H)
        let quad: [SIMD4<Float>] = [
            SIMD4(-0.5, -0.5, 0, 1), SIMD4(0.5, -0.5, 0, 1), SIMD4(0.5, 0.5, 0, 1),
            SIMD4(-0.5, -0.5, 0, 1), SIMD4(0.5,  0.5, 0, 1), SIMD4(-0.5, 0.5, 0, 1)]
        let qbuf = GPU.shared.device.makeBuffer(bytes: quad,
            length: MemoryLayout<SIMD4<Float>>.stride * quad.count, options: .storageModeShared)!

        let aspect = Float(W) / Float(H)
        let proj = CubeView.perspective(fovY: 0.9, aspect: aspect, near: 0.1, far: 10)
        let view = CubeView.lookAt(eye: SIMD3(0, 0, 2.3), center: .zero, up: SIMD3(0, 1, 0))
        let step = Float.pi / 2

        var out: [CGImage] = []
        let count = 40
        for i in 0..<count {
            let t = Float(i) / Float(count - 1)
            let eased = t * t * (3 - 2 * t)
            let cubeRot = CubeView.rotationY(-eased * step)

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.colorAttachments[0].storeAction = .store
            guard let cmd = GPU.shared.queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            enc.setRenderPipelineState(GPU.shared.cubePipeline)
            enc.setVertexBuffer(qbuf, offset: 0, index: 0)
            for (slot, face) in [faceA, faceB].enumerated() {
                var model = CubeView.rotationY(Float(slot) * step)
                model = CubeView.matMul(model, CubeView.translation(SIMD3(0, 0, 0.5)))
                let mvp = CubeView.matMul(proj, CubeView.matMul(view, CubeView.matMul(cubeRot, model)))
                var cu = CubeUniforms(mvp: mvp, dim: 1, _pad: .zero)
                withUnsafeBytes(of: &cu) {
                    enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                    enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
                }
                enc.setFragmentTexture(face, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            if let img = readback(target) { out.append(img) }
        }
        return out
    }

    // MARK: helpers
    private static func makeTarget(_ w: Int, _ h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        return GPU.shared.device.makeTexture(descriptor: d)!
    }

    private static func readback(_ t: MTLTexture) -> CGImage? {
        let w = t.width, h = t.height, bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        t.getBytes(&bytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bmp = CGBitmapInfo.byteOrder32Little.rawValue |
                  CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: cs, bitmapInfo: bmp) else { return nil }
        return ctx.makeImage()
    }
}
