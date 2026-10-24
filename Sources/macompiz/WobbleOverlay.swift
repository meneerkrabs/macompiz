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
    private let sim = WobbleSim()
    private let lattice: MTLBuffer
    private var uniforms = WindowUniforms()
    private var clock: Float = 0
    private var last = CACurrentMediaTime()

    init(frame: CGRect, capture: LiveCapture) {
        self.capture = capture
        lattice = GPU.shared.device.makeBuffer(
            length: WobbleSim.N * WobbleSim.N * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared)!
        super.init(frame: frame, device: GPU.shared.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        delegate = self
        uniforms.aspect = Float(frame.width / max(1, frame.height))
        uniforms.grabActive = 1
        uniforms.animKind = 0
    }
    required init(coder: NSCoder) { fatalError() }

    // feed the window motion into the spring lattice
    func feed(dx: CGFloat, dy: CGFloat, dt: Float) {
        sim.tug(SIMD2(Float(dx) / Float(bounds.width), Float(dy) / Float(bounds.height)))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime(); let dt = Float(now - last); last = now; clock += dt
        sim.step(dt)
        sim.disp.withUnsafeBytes { memcpy(lattice.contents(), $0.baseAddress!, $0.count) }
        guard let tex = capture.texture else { return }

        uniforms.time = clock
        guard let drawable = currentDrawable,
              let rpd = currentRenderPassDescriptor,
              let cmd = GPU.shared.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(GPU.shared.wobblePipeline)
        enc.setVertexBuffer(GPU.shared.gridBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(lattice, offset: 0, index: 2)
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
