import AppKit
import MetalKit
import simd

// Full-screen overlay that spins the desktop like Compiz's desktop cube to
// switch "spaces". For a SIP-friendly v1 the spaces are synthetic textures
// (see SpaceFactory); wiring real captures would use ScreenCaptureKit.
final class CubeWindow: NSWindow {
    let cubeView: CubeView
    init(screen: NSScreen, faces: [MTLTexture], from: Int, to: Int, onDone: @escaping () -> Void) {
        cubeView = CubeView(frame: screen.frame, faces: faces, from: from, to: to, onDone: onDone)
        super.init(contentRect: screen.frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .black
        level = .mainMenu + 1
        contentView = cubeView
    }
    override var canBecomeKey: Bool { true }
}

final class CubeView: MTKView, MTKViewDelegate {
    private let faces: [MTLTexture]
    private let fromIndex: Int
    private let toIndex: Int
    private let onDone: () -> Void

    private var t: Float = 0          // 0..1 animation progress
    private var last = CACurrentMediaTime()
    private let faceCount: Int
    private var quad: MTLBuffer!

    init(frame: CGRect, faces: [MTLTexture], from: Int, to: Int, onDone: @escaping () -> Void) {
        self.faces = faces
        self.faceCount = max(1, faces.count)
        self.fromIndex = from
        self.toIndex = to
        self.onDone = onDone
        super.init(frame: frame, device: GPU.shared.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        delegate = self
        buildQuad()
    }
    required init(coder: NSCoder) { fatalError() }

    private func buildQuad() {
        // face-local quad in [-0.5,0.5], two triangles
        let v: [SIMD4<Float>] = [
            SIMD4(-0.5, -0.5, 0, 1), SIMD4(0.5, -0.5, 0, 1), SIMD4(0.5, 0.5, 0, 1),
            SIMD4(-0.5, -0.5, 0, 1), SIMD4(0.5,  0.5, 0, 1), SIMD4(-0.5, 0.5, 0, 1),
        ]
        quad = GPU.shared.device.makeBuffer(bytes: v,
                length: MemoryLayout<SIMD4<Float>>.stride * v.count, options: .storageModeShared)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(now - last); last = now
        t = min(1, t + dt / 0.8)            // 0.8s sweep
        let eased = t * t * (3 - 2 * t)     // smoothstep

        // one 90° step from `from` face to the adjacent `to` face
        let step = Float.pi / 2
        let angle = -eased * step           // rotate cube so next face comes forward

        let aspect = Float(bounds.width / max(1, bounds.height))
        let proj = CubeView.perspective(fovY: 0.9, aspect: aspect, near: 0.1, far: 10)
        let view4 = CubeView.lookAt(eye: SIMD3(0, 0, 2.3),
                                    center: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))
        let cubeRot = CubeView.rotationY(angle)

        guard let drawable = currentDrawable,
              let rpd = currentRenderPassDescriptor,
              let cmd = GPU.shared.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(GPU.shared.cubePipeline)
        enc.setVertexBuffer(quad, offset: 0, index: 0)

        // draw the two faces involved on cube sides (radius 0.5)
        let order = [fromIndex, toIndex]
        for (slot, faceIdx) in order.enumerated() {
            let faceAngle = Float(slot) * step          // 0 and +90
            var model = CubeView.rotationY(faceAngle)
            model = CubeView.matMul(model, CubeView.translation(SIMD3(0, 0, 0.5)))
            let mvp = CubeView.matMul(proj,
                        CubeView.matMul(view4, CubeView.matMul(cubeRot, model)))
            var u = CubeUniforms(mvp: mvp, dim: 1.0, _pad: .zero)
            withUnsafeBytes(of: &u) { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                                      enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            enc.setFragmentTexture(faces[min(faceIdx, faces.count - 1)], index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()

        if t >= 1 { onDone() }
    }

    // MARK: simd matrix helpers
    static func matMul(_ a: float4x4, _ b: float4x4) -> float4x4 { a * b }
    static func translation(_ v: SIMD3<Float>) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(v.x, v.y, v.z, 1); return m
    }
    static func rotationY(_ a: Float) -> float4x4 {
        let c = cos(a), s = sin(a)
        return float4x4(SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0),
                        SIMD4(s, 0,  c, 0), SIMD4(0, 0, 0, 1))
    }
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let ys = 1 / tan(fovY * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return float4x4(SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0),
                        SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * near, 0))
    }
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let z = simd_normalize(eye - center)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return float4x4(SIMD4(x.x, y.x, z.x, 0),
                        SIMD4(x.y, y.y, z.y, 0),
                        SIMD4(x.z, y.z, z.z, 0),
                        SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1))
    }
}
