import AppKit
import Metal

// Builds synthetic "space" textures for the cube transition: a gradient desktop
// with a note card composited on top. Real Spaces capture would need
// ScreenCaptureKit + the Screen Recording permission; kept out of v1 on purpose.
enum SpaceFactory {
    static func space(label: String, body: String, hueTop: NSColor, hueBottom: NSColor,
                      pixelSize: CGSize) -> MTLTexture {
        let img = NSImage(size: pixelSize)
        img.lockFocus()

        let grad = NSGradient(starting: hueTop, ending: hueBottom)!
        grad.draw(in: CGRect(origin: .zero, size: pixelSize), angle: -90)

        let noteSize = CGSize(width: min(520, pixelSize.width * 0.42),
                              height: min(360, pixelSize.height * 0.42))
        let note = NoteRenderer.image(title: "TextEdit", body: "# \(label)\n\n\(body)",
                                      size: noteSize)
        let nx = (pixelSize.width - noteSize.width) / 2
        let ny = (pixelSize.height - noteSize.height) / 2
        note.draw(in: CGRect(x: nx, y: ny, width: noteSize.width, height: noteSize.height))

        img.unlockFocus()
        return GPU.shared.texture(from: img, pixelSize: pixelSize)
    }
}
