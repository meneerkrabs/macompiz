import AppKit
import MetalKit
import simd

// A borderless note window. Its chrome (traffic lights, title) is drawn into the
// texture by NoteRenderer, and a Metal view distorts that texture for the
// effects: drag = wobbly, click = water ripple, red light = burn-to-close.
final class NoteWindow: NSWindow {
    let noteView: NoteMetalView

    init(title: String, body: String, origin: CGPoint, size: CGSize) {
        noteView = NoteMetalView(title: title, body: body, size: size)
        super.init(contentRect: CGRect(origin: origin, size: size),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .normal
        isMovableByWindowBackground = false
        contentView = noteView
        noteView.hostWindow = self
    }

    // Overlay that floats a captured foreign window's pixels, so the effect
    // pipeline (burn/wobble/water) can run on top of another app's window.
    init(foreignTexture tex: MTLTexture, frame: CGRect) {
        noteView = NoteMetalView(externalTexture: tex, size: frame.size)
        super.init(contentRect: frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = noteView
        noteView.hostWindow = self
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class NoteMetalView: MTKView, MTKViewDelegate {
    weak var hostWindow: NoteWindow?

    private var texture: MTLTexture!
    private let noteTitle: String
    private let noteBody: String
    private let noteSize: CGSize

    private var uniforms = WindowUniforms()
    private var clock: Float = 0
    private var lastTick = CACurrentMediaTime()

    // wobble state
    private var grabbing = false
    private var vel = SIMD2<Float>(0, 0)
    private var lastDragWindowOrigin = CGPoint.zero

    // water ripples (ring buffer of 8)
    private var ripples = [SIMD4<Float>](repeating: .zero, count: 8)
    private var rippleHead = 0

    // burn
    private var burning = false
    private var burnProgress: Float = 0
    var onBurnedAway: (() -> Void)?

    private let external: Bool

    init(title: String, body: String, size: CGSize) {
        self.noteTitle = title
        self.noteBody = body
        self.noteSize = size
        self.external = false
        super.init(frame: CGRect(origin: .zero, size: size), device: GPU.shared.device)
        configure(size: size)
        rebuildTexture()
    }

    // Overlay a captured foreign window: same effect pipeline, but the texture
    // is supplied by the caller (a ScreenCaptureKit grab) instead of a note.
    init(externalTexture tex: MTLTexture, size: CGSize) {
        self.noteTitle = ""
        self.noteBody = ""
        self.noteSize = size
        self.external = true
        super.init(frame: CGRect(origin: .zero, size: size), device: GPU.shared.device)
        configure(size: size)
        texture = tex
    }

    required init(coder: NSCoder) { fatalError() }

    private func configure(size: CGSize) {
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        delegate = self
        uniforms.aspect = Float(size.width / size.height)
    }

    private func rebuildTexture() {
        guard !external else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let px = CGSize(width: noteSize.width * scale, height: noteSize.height * scale)
        let img = NoteRenderer.image(title: noteTitle, body: noteBody, size: px)
        texture = GPU.shared.texture(from: img, pixelSize: px)
    }

    // MARK: input

    private func uv(for event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        return SIMD2(Float(p.x / bounds.width), Float(1 - p.y / bounds.height))
    }

    override func mouseDown(with event: NSEvent) {
        let u = uv(for: event)
        // red traffic light hit region (top-left of the drawn titlebar)
        if u.y < 0.12 && u.x < 0.10 {
            startBurn(); return
        }
        spawnRipple(at: u)
        grabbing = true
        uniforms.grabPoint = u
        vel = .zero
        lastDragWindowOrigin = hostWindow?.frame.origin ?? .zero
        hostWindow?.makeKeyAndOrderFront(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = hostWindow else { return }
        // move the window with the cursor
        let d = CGSize(width: event.deltaX, height: -event.deltaY)
        var o = w.frame.origin
        o.x += d.width; o.y += d.height
        w.setFrameOrigin(o)
        // velocity in uv/sec feeds the jelly lag
        let dt = max(1.0 / 120.0, Float(CACurrentMediaTime() - lastTick))
        vel = SIMD2(Float(d.width) / Float(bounds.width),
                    Float(d.height) / Float(bounds.height)) / dt
        vel = simd_clamp(vel, SIMD2(-6, -6), SIMD2(6, 6))
    }

    override func mouseUp(with event: NSEvent) {
        grabbing = false   // velocity decays in the tick loop -> settles
    }

    func startBurn() {
        guard !burning else { return }
        burning = true
    }

    private func spawnRipple(at uvPoint: SIMD2<Float>) {
        ripples[rippleHead] = SIMD4(uvPoint.x, uvPoint.y, clock, 1)
        rippleHead = (rippleHead + 1) % ripples.count
    }

    // Public hook used by the demo script to splash the aquarium.
    func splash(at uvPoint: SIMD2<Float> = SIMD2(0.5, 0.5)) { spawnRipple(at: uvPoint) }

    // MARK: render loop

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(now - lastTick)
        lastTick = now
        clock += dt

        // settle wobble
        if !grabbing { vel *= pow(0.0025, dt) }  // fast exponential decay
        if simd_length(vel) < 0.01 { vel = .zero }
        uniforms.grabActive = (grabbing || simd_length(vel) > 0.02) ? 1 : 0
        uniforms.grabVel = vel

        // advance burn
        if burning {
            burnProgress = min(1, burnProgress + dt * 0.9)
            uniforms.burn = burnProgress
            if burnProgress >= 1 {
                burning = false
                onBurnedAway?()
                hostWindow?.orderOut(nil)
                return
            }
        }

        uniforms.time = clock
        uniforms.ripples = (ripples[0], ripples[1], ripples[2], ripples[3],
                            ripples[4], ripples[5], ripples[6], ripples[7])
        uniforms.rippleCount = Float(ripples.count)

        guard let drawable = currentDrawable,
              let rpd = currentRenderPassDescriptor,
              let cmd = GPU.shared.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        enc.setRenderPipelineState(GPU.shared.windowPipeline)
        enc.setVertexBuffer(GPU.shared.gridBuffer, offset: 0, index: 0)
        withUnsafeBytes(of: &uniforms) { p in
            enc.setVertexBytes(p.baseAddress!, length: p.count, index: 1)
            enc.setFragmentBytes(p.baseAddress!, length: p.count, index: 1)
        }
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: GPU.shared.gridCount)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
