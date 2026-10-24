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
}

final class WobbleView: MTKView, MTKViewDelegate {
    private let capture: LiveCapture
    private let sim = WobbleSim()
    private let lattice: MTLBuffer
    private var uniforms = WindowUniforms()
    private var clock: Float = 0
    private var last = CACurrentMediaTime()

    // self-positioning: the view parks its own window under the cursor each frame
    var cursorProvider: (() -> CGPoint)?    // latest cursor in CG (top-left) coords
    var grabOffsetCG = CGPoint.zero         // cursor - window origin, at grab time
    private let screenH = CGDisplayBounds(CGMainDisplayID()).height
    private var lastOriginCG: CGPoint?

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

    func setGrab(_ uv: SIMD2<Float>) { sim.grab = uv }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime(); let dt = Float(now - last); last = now; clock += dt

        // keep the window exactly under the cursor, and feed its motion as wobble
        if let cp = cursorProvider?() {
            let originCG = CGPoint(x: cp.x - grabOffsetCG.x, y: cp.y - grabOffsetCG.y)
            if let prev = lastOriginCG {
                let ddx = Float(originCG.x - prev.x), ddy = Float(originCG.y - prev.y)
                sim.tug(SIMD2(ddx / Float(bounds.width), ddy / Float(bounds.height)))
            }
            lastOriginCG = originCG
            window?.setFrameOrigin(CGPoint(x: originCG.x, y: screenH - (originCG.y + bounds.height)))
        }

        sim.step(dt)
        _ = sim.disp.withUnsafeBytes { memcpy(lattice.contents(), $0.baseAddress!, $0.count) }
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
