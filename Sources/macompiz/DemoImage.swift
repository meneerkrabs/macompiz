import AppKit

// Offscreen renderer for README art. `macompiz --render-demo <path>` draws a
// wallpaper + note cards to a PNG and exits — no windows, no screen capture.
enum DemoImage {
    static func write(to path: String) {
        let size = CGSize(width: 1280, height: 860)
        let img = NSImage(size: size)
        img.lockFocus()

        NSGradient(starting: NSColor(srgbRed: 0.76, green: 0.87, blue: 0.98, alpha: 1),
                   ending: NSColor(srgbRed: 0.10, green: 0.42, blue: 0.78, alpha: 1))!
            .draw(in: CGRect(origin: .zero, size: size), angle: -90)

        let main = NoteRenderer.image(
            title: "macompiz",
            body: "# MacOS Compiz?\n\nHello world,\n\nDid you know you can do real\n**Compiz** effects on macOS?\n\nDrag me to *wobble*. Click for `water`.\nHit the red light to **BURN** me.",
            size: CGSize(width: 520, height: 360))
        main.draw(in: CGRect(x: 120, y: 360, width: 520, height: 360))

        let second = NoteRenderer.image(
            title: "TextEdit",
            body: "# 3D Spaces?\n\nSwitch spaces via **cube**\nrotation. ⌘] / ⌘[",
            size: CGSize(width: 460, height: 300))
        second.draw(in: CGRect(x: 640, y: 150, width: 460, height: 300))

        img.unlockFocus()

        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("demo render failed\n".utf8)); exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
