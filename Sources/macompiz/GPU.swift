import Metal
import MetalKit
import AppKit

// Process-wide Metal context + compiled pipelines. Shaders are compiled from
// `metalSource` at launch, so a plain Swift toolchain (no `metal` CLI) is enough.
final class GPU {
    static let shared = GPU()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let windowPipeline: MTLRenderPipelineState
    let cubePipeline: MTLRenderPipelineState
    let gridBuffer: MTLBuffer
    let gridCount: Int

    static let gridDim = 24   // 24x24 cells -> smooth wobble/water

    private init() {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            fatalError("macompiz: no Metal device")
        }
        device = dev
        queue = dev.makeCommandQueue()!

        let lib: MTLLibrary
        do {
            lib = try dev.makeLibrary(source: metalSource, options: nil)
        } catch {
            fatalError("macompiz: shader compile failed: \(error)")
        }

        windowPipeline = GPU.makePipeline(dev, lib, "window_vertex", "window_fragment")
        cubePipeline   = GPU.makePipeline(dev, lib, "cube_vertex",   "cube_fragment")

        let (verts, count) = GPU.makeGrid(GPU.gridDim)
        gridBuffer = dev.makeBuffer(bytes: verts,
                                    length: MemoryLayout<SIMD2<Float>>.stride * count,
                                    options: .storageModeShared)!
        gridCount = count
    }

    private static func makePipeline(_ dev: MTLDevice, _ lib: MTLLibrary,
                                     _ vfn: String, _ ffn: String) -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: vfn)
        d.fragmentFunction = lib.makeFunction(name: ffn)
        let c = d.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        c.isBlendingEnabled = true
        c.rgbBlendOperation = .add
        c.alphaBlendOperation = .add
        c.sourceRGBBlendFactor = .sourceAlpha
        c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try! dev.makeRenderPipelineState(descriptor: d)
    }

    // A triangle list over an N×N grid of cells, as uv coords in 0..1.
    private static func makeGrid(_ n: Int) -> ([SIMD2<Float>], Int) {
        var v: [SIMD2<Float>] = []
        v.reserveCapacity(n * n * 6)
        let step = 1.0 / Float(n)
        for y in 0..<n {
            for x in 0..<n {
                let x0 = Float(x) * step, x1 = Float(x + 1) * step
                let y0 = Float(y) * step, y1 = Float(y + 1) * step
                v.append(SIMD2(x0, y0)); v.append(SIMD2(x1, y0)); v.append(SIMD2(x1, y1))
                v.append(SIMD2(x0, y0)); v.append(SIMD2(x1, y1)); v.append(SIMD2(x0, y1))
            }
        }
        return (v, v.count)
    }

    // Rasterize an NSImage into a BGRA texture at the given pixel size.
    func texture(from image: NSImage, pixelSize: CGSize) -> MTLTexture {
        let w = max(1, Int(pixelSize.width))
        let h = max(1, Int(pixelSize.height))
        let bytesPerRow = w * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bmp = CGBitmapInfo.byteOrder32Little.rawValue |
                  CGImageAlphaInfo.premultipliedFirst.rawValue
        let cg = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 8,
                           bytesPerRow: bytesPerRow, space: cs, bitmapInfo: bmp)!
        let ns = NSGraphicsContext(cgContext: cg, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        image.draw(in: CGRect(x: 0, y: 0, width: w, height: h),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        let tex = device.makeTexture(descriptor: desc)!
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: raw, bytesPerRow: bytesPerRow)
        return tex
    }
}
