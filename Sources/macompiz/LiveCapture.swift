import AppKit
import ScreenCaptureKit
import CoreVideo
import Metal

// Continuous live capture of a single window via SCStream, exposed as the latest
// Metal texture. Used by the wobble daemon so the floating copy shows the real,
// updating window content (video keeps playing) while it jiggles — all SIP-on.
final class LiveCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var cache: CVMetalTextureCache?
    private let lock = NSLock()
    private var _tex: MTLTexture?
    private var _hold: CVMetalTexture?   // keep the latest CV texture alive

    var texture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }; return _tex
    }

    override init() {
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, GPU.shared.device, nil, &cache)
    }

    func start(window: SCWindow) async {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        cfg.width = Int(window.frame.width * scale)
        cfg.height = Int(window.frame.height * scale)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.queueDepth = 3
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        do {
            try s.addStreamOutput(self, type: .screen,
                                  sampleHandlerQueue: DispatchQueue(label: "macompiz.wobble.capture"))
            try await s.startCapture()
            stream = s
        } catch {
            FileHandle.standardError.write(Data("wobble: capture start failed (\(error))\n".utf8))
        }
    }

    func stop() {
        stream?.stopCapture(completionHandler: { _ in })
        stream = nil
        lock.lock(); _tex = nil; _hold = nil; lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              let px = CMSampleBufferGetImageBuffer(sb), let cache else { return }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        var cv: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, px, nil, .bgra8Unorm, w, h, 0, &cv)
        guard r == kCVReturnSuccess, let cv, let mtl = CVMetalTextureGetTexture(cv) else { return }
        lock.lock(); _tex = mtl; _hold = cv; lock.unlock()
    }
}
