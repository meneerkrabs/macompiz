import AppKit
import simd

@main
final class App {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--render-demo"),
           i + 1 < CommandLine.arguments.count {
            DemoImage.write(to: CommandLine.arguments[i + 1])
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notes: [NoteWindow] = []
    private var cubeWindow: CubeWindow?
    private var currentSpace = 0

    private let spaces: [(label: String, body: String, top: NSColor, bottom: NSColor)] = [
        ("MacOS Compiz?",
         "Drag me to **wobble**. Click me for **water**. Hit the red light to **burn**.",
         NSColor(srgbRed: 0.75, green: 0.86, blue: 0.98, alpha: 1),
         NSColor(srgbRed: 0.12, green: 0.45, blue: 0.80, alpha: 1)),
        ("3D Spaces?",
         "Press **⌘→ / ⌘←** to rotate the cube between spaces.",
         NSColor(srgbRed: 0.98, green: 0.90, blue: 0.75, alpha: 1),
         NSColor(srgbRed: 0.20, green: 0.55, blue: 0.70, alpha: 1)),
        ("Compiz is back baby!",
         "And yea, you can also make TextEdit understand **Markdown** too.",
         NSColor(srgbRed: 0.88, green: 0.80, blue: 0.98, alpha: 1),
         NSColor(srgbRed: 0.35, green: 0.25, blue: 0.70, alpha: 1)),
    ]

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        openNotes()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openNotes() {
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let samples: [(String, String, CGPoint, CGSize)] = [
            ("macompiz",
             "# MacOS Compiz?\n\nHello world,\n\nDid you know that you can just decompile macOS\ncompositing pipeline and do whatever you want\nwith it?\n\nFor example,\n\nI can close this window by **BURNING** it.",
             CGPoint(x: f.midX - 230, y: f.midY - 40), CGSize(width: 460, height: 320)),
        ]
        for (t, b, o, s) in samples {
            let w = NoteWindow(title: t, body: b, origin: o, size: s)
            w.noteView.onBurnedAway = { [weak self, weak w] in
                guard let w = w else { return }
                self?.notes.removeAll { $0 === w }
            }
            w.makeKeyAndOrderFront(nil)
            notes.append(w)
        }
    }

    // MARK: cube space switching

    private func switchSpace(delta: Int) {
        guard cubeWindow == nil, let screen = NSScreen.main else { return }
        let next = (currentSpace + delta + spaces.count) % spaces.count
        let scale = screen.backingScaleFactor
        let px = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)

        let fromTex = tex(for: currentSpace, px: px)
        let toTex = tex(for: next, px: px)

        let cube = CubeWindow(screen: screen, faces: [fromTex, toTex], from: 0, to: 1) { [weak self] in
            self?.endCube(landingOn: next)
        }
        notes.forEach { $0.orderOut(nil) }
        cube.makeKeyAndOrderFront(nil)
        cubeWindow = cube
    }

    private func tex(for i: Int, px: CGSize) -> MTLTexture {
        let s = spaces[i]
        return SpaceFactory.space(label: s.label, body: s.body,
                                  hueTop: s.top, hueBottom: s.bottom, pixelSize: px)
    }

    private func endCube(landingOn index: Int) {
        currentSpace = index
        cubeWindow?.orderOut(nil)
        cubeWindow = nil
        // re-show notes only on the first space, mirroring the demo
        if index == 0 { notes.forEach { $0.makeKeyAndOrderFront(nil) } }
    }

    // MARK: menu / shortcuts

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit macompiz", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fx = NSMenuItem()
        main.addItem(fx)
        let fxMenu = NSMenu(title: "Effects")
        fx.submenu = fxMenu
        fxMenu.title = "Effects"
        add(fxMenu, "Next space (cube)",  #selector(nextSpace), "]")
        add(fxMenu, "Prev space (cube)",  #selector(prevSpace), "[")
        add(fxMenu, "Splash (water)",     #selector(splash),    "w")
        add(fxMenu, "New note",           #selector(newNote),   "n")

        NSApp.mainMenu = main
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func nextSpace() { switchSpace(delta: 1) }
    @objc private func prevSpace() { switchSpace(delta: -1) }
    @objc private func splash() { notes.forEach { $0.noteView.splash() } }
    @objc private func newNote() {
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let w = NoteWindow(title: "Untitled",
                           body: "# New note\n\nType *markdown*, then **burn** it.",
                           origin: CGPoint(x: f.midX - 150 + CGFloat(notes.count) * 24,
                                           y: f.midY - 110 - CGFloat(notes.count) * 24),
                           size: CGSize(width: 360, height: 240))
        w.noteView.onBurnedAway = { [weak self, weak w] in
            guard let w = w else { return }; self?.notes.removeAll { $0 === w } }
        w.makeKeyAndOrderFront(nil)
        notes.append(w)
    }
}
