import simd

// Spring-mass lattice, the model Compiz Fusion's wobbly windows use. An NxN grid
// of masses linked by springs; the grabbed node is pinned to the window while the
// rest lag and oscillate, giving the gooey jelly trail. Simulated on the CPU each
// frame; the displacements feed the wobble vertex shader as a lattice. N must
// match the constant in wobble_vertex (Shaders.swift).
final class WobbleSim {
    static let N = 11

    private(set) var disp: [SIMD2<Float>]   // per-node displacement in uv space
    private var vel: [SIMD2<Float>]
    var grab = SIMD2<Float>(0.5, 0.08)       // grabbed point in uv (near titlebar)

    // Tuned for a Compiz-ish bounce: stiff springs, light damping = several
    // visible oscillations before it settles.
    private let kStruct: Float = 320
    private let kAnchor: Float = 22
    private let damp: Float = 3.0

    init() {
        let c = WobbleSim.N * WobbleSim.N
        disp = Array(repeating: .zero, count: c)
        vel = Array(repeating: .zero, count: c)
    }

    private func grabIndex() -> Int {
        let n = WobbleSim.N
        let gx = min(max(Int((grab.x * Float(n - 1)).rounded()), 0), n - 1)
        let gy = min(max(Int((grab.y * Float(n - 1)).rounded()), 0), n - 1)
        return gy * n + gx
    }

    /// The window moved by `duv` (uv); free nodes lag behind, farther nodes more
    /// (distance-weighted) for the gooey Compiz curve rather than a rigid lean.
    func tug(_ duv: SIMD2<Float>) {
        let n = WobbleSim.N
        let gx = grab.x * Float(n - 1), gy = grab.y * Float(n - 1)
        let maxD = Float(n - 1) * 1.414
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
                let d = hypot(Float(x) - gx, Float(y) - gy) / maxD      // 0..1
                let w = min(1.0, 0.25 + d * 1.6)                        // near lags less
                disp[i] = simd_clamp(disp[i] - duv * w, SIMD2(-0.6, -0.6), SIMD2(0.6, 0.6))
            }
        }
    }

    func step(_ dt: Float) {
        let n = WobbleSim.N
        let h = min(max(dt, 1.0 / 240), 1.0 / 60)   // clamp for stability
        let gi = grabIndex()
        var force = [SIMD2<Float>](repeating: .zero, count: disp.count)
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
                if i == gi { continue }
                var f = -kAnchor * disp[i]
                if x > 0     { f += kStruct * (disp[i - 1] - disp[i]) }
                if x < n - 1 { f += kStruct * (disp[i + 1] - disp[i]) }
                if y > 0     { f += kStruct * (disp[i - n] - disp[i]) }
                if y < n - 1 { f += kStruct * (disp[i + n] - disp[i]) }
                f -= damp * vel[i]
                force[i] = f
            }
        }
        for i in 0..<disp.count {
            if i == gi { disp[i] = .zero; vel[i] = .zero; continue }
            vel[i] += force[i] * h
            disp[i] += vel[i] * h
        }
    }

    var settled: Bool {
        var e: Float = 0
        for v in vel { e += simd_length_squared(v) }
        for d in disp { e += simd_length_squared(d) }
        return e < 1e-5
    }
}
