import AppKit
import MetalKit
import simd

// A borderless, click-through overlay that floats a window's live capture and
// runs the wobbly-windows shader on it, driven by cursor velocity. It tracks the
// real window (which macOS keeps moving) by following the drag deltas.
final class WobbleOverlay: NSWindow {
    let view: WobbleView

    init(frame: CGRect, capture: LiveCapture) {
        view = WobbleView(frame: CGRect(origin: .zero, size: frame.size), capture: capture)
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true   // never steal the user's drag
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = view
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        var o = frame.origin
        o.x += dx; o.y += dy
        setFrameOrigin(o)
    }
}

final class WobbleView: MTKView, MTKViewDelegate {
    private let capture: LiveCapture
    private var uniforms = WindowUniforms()
    private var vel = SIMD2<Float>(0, 0)
    private var clock: Float = 0
    private var last = CACurrentMediaTime()

    init(frame: CGRect, capture: LiveCapture) {
        self.capture = capture
        super.init(frame: frame, device: GPU.shared.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        delegate = self
        uniforms.aspect = Float(frame.width / max(1, frame.height))
    }
    required init(coder: NSCoder) { fatalError() }

    // cursor velocity in points/sec -> uv/sec for the jelly lag
    func feed(dx: CGFloat, dy: CGFloat, dt: Float) {
        let v = SIMD2(Float(dx) / Float(bounds.width), Float(-dy) / Float(bounds.height)) / max(dt, 1/120)
        vel = simd_clamp(v, SIMD2(-6, -6), SIMD2(6, 6))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime(); let dt = Float(now - last); last = now; clock += dt
        vel *= pow(0.02, dt)                       // settle
        if simd_length(vel) < 0.01 { vel = .zero }
        guard let tex = capture.texture else { return }

        uniforms.grabActive = 1
        uniforms.grabPoint = SIMD2(0.5, 0.12)      // grabbed near the titlebar
        uniforms.grabVel = vel
        uniforms.time = clock
        uniforms.animKind = 0

        guard let drawable = currentDrawable,
              let rpd = currentRenderPassDescriptor,
              let cmd = GPU.shared.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(GPU.shared.windowPipeline)
        enc.setVertexBuffer(GPU.shared.gridBuffer, offset: 0, index: 0)
        withUnsafeBytes(of: &uniforms) {
            enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
            enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: GPU.shared.gridCount)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
