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
        if CommandLine.arguments.contains("--test-foreign") {
            _ = NSApplication.shared
            Task {
                let b = Bridges.resolve()
                print("bridge=\(b.name) available=\(b.available)")
                let wins = await ScreenCapture.foreignWindows()
                print("foreign windows: \(wins.count)")
                for w in wins.prefix(5) {
                    print("  id=\(w.windowID) app=\(w.owningApplication?.applicationName ?? "?") " +
                          "title=\(w.title ?? "") frame=\(w.frame)")
                }
                if let first = wins.first, let cg = await ScreenCapture.captureWindow(first) {
                    print("captured first window: \(cg.width)x\(cg.height)")
                } else {
                    print("no window captured")
                }
                exit(0)
            }
            NSApplication.shared.run()
        }
        if CommandLine.arguments.contains("--test-spaces") {
            let sl = SkyLight.shared
            print("SkyLight available=\(sl.available) canSwitch=\(sl.canSwitch) cid=\(sl.cid)")
            if let ds = sl.mainDisplaySpaces() {
                print("spaces=\(ds.spaceIDs) current=\(ds.currentID) index=\(ds.currentIndex)")
            } else {
                print("could not enumerate spaces")
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--test-capture") {
            _ = NSApplication.shared          // TCC needs an app context
            Task {
                guard let screen = NSScreen.main else { exit(2) }
                if let cg = await ScreenCapture.capture(screen: screen) {
                    print("capture OK: \(cg.width)x\(cg.height)")
                    exit(0)
                } else {
                    print("capture FAILED (permission denied or unavailable)")
                    exit(3)
                }
            }
            NSApplication.shared.run()
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

    // Privileged bridge for touching foreign apps' windows (yabai or none).
    private lazy var bridge: CompositorBridge = Bridges.resolve()
    private var foreignOverlays: [NoteWindow] = []

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

    // Cached synthetic/real faces for spaces we fall back on.
    private var realFaces: [Int: MTLTexture] = [:]

    private func switchSpace(delta: Int) {
        guard cubeWindow == nil, let screen = NSScreen.main else { return }
        let px = pxSize(screen)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let sl = SkyLight.shared

            // outgoing face = the real current desktop (notes still visible)
            let texA = await self.captureTex(screen: screen, exclude: [])
                       ?? self.tex(for: self.currentSpace, px: px)

            // --- real space switch via SkyLight -----------------------------
            if sl.available, sl.canSwitch,
               let ds = sl.mainDisplaySpaces(), ds.spaceIDs.count > 1 {
                let tIdx = (ds.currentIndex + delta + ds.spaceIDs.count) % ds.spaceIDs.count
                let targetSID = ds.spaceIDs[tIdx]

                // mask the raw OS switch behind a sticky cover window
                let cover = self.makeCover(screen: screen)
                cover.orderFrontRegardless()
                let coverID = CGWindowID(cover.windowNumber)

                if sl.setCurrentSpace(targetSID) {
                    try? await Task.sleep(nanoseconds: 220_000_000)   // let it settle
                    let texB = await self.captureTex(screen: screen, exclude: [coverID])
                               ?? self.tex(for: min(tIdx, self.spaces.count - 1), px: px)
                    cover.orderOut(nil)
                    self.runCube(screen: screen, from: texA, to: texB) { [weak self] in
                        self?.currentSpace = min(tIdx, (self?.spaces.count ?? 1) - 1)
                    }
                    return
                }
                cover.orderOut(nil)   // OS refused the switch -> synthetic below
            }

            // --- fallback: synthetic cube, no real switch -------------------
            let next = (self.currentSpace + delta + self.spaces.count) % self.spaces.count
            self.realFaces[self.currentSpace] = texA
            let texB = self.realFaces[next] ?? self.tex(for: next, px: px)
            self.runCube(screen: screen, from: texA, to: texB) { [weak self] in
                self?.currentSpace = next
            }
        }
    }

    private func runCube(screen: NSScreen, from: MTLTexture, to: MTLTexture,
                         onLand: @escaping () -> Void) {
        let cube = CubeWindow(screen: screen, faces: [from, to], from: 0, to: 1) { [weak self] in
            onLand()
            self?.cubeWindow?.orderOut(nil)
            self?.cubeWindow = nil
        }
        cube.makeKeyAndOrderFront(nil)
        cubeWindow = cube
    }

    private func captureTex(screen: NSScreen, exclude: [CGWindowID]) async -> MTLTexture? {
        if let cg = await ScreenCapture.capture(screen: screen, exclude: exclude) {
            return GPU.shared.texture(from: cg)
        }
        return nil
    }

    private func makeCover(screen: NSScreen) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isOpaque = true
        w.backgroundColor = .black
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return w
    }

    private func pxSize(_ screen: NSScreen) -> CGSize {
        let s = screen.backingScaleFactor
        return CGSize(width: screen.frame.width * s, height: screen.frame.height * s)
    }

    private func tex(for i: Int, px: CGSize) -> MTLTexture {
        let s = spaces[i]
        return SpaceFactory.space(label: s.label, body: s.body,
                                  hueTop: s.top, hueBottom: s.bottom, pixelSize: px)
    }

    // MARK: foreign windows (capture + overlay effect)

    // Burn the frontmost other-app window: capture it, hide the real one via the
    // bridge (if present), and run the burn on a floating copy. Without a bridge
    // it's a visual-only overlay — the effect plays but the real window stays.
    @objc private func burnForeground() {
        guard let screen = NSScreen.main else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wins = await ScreenCapture.foreignWindows()
            guard let target = wins.first,
                  let cg = await ScreenCapture.captureWindow(target) else {
                NSSound.beep(); return
            }
            let tex = GPU.shared.texture(from: cg)
            let frame = self.toAppKitFrame(target.frame, screen: screen)
            let overlay = NoteWindow(foreignTexture: tex, frame: frame)
            let wid = CGWindowID(target.windowID)
            let hid = self.bridge.available
            if hid { self.bridge.setOpacity(wid, 0.0) }

            overlay.noteView.onBurnedAway = { [weak self, weak overlay] in
                overlay?.orderOut(nil)
                if let overlay { self?.foreignOverlays.removeAll { $0 === overlay } }
                if hid { self?.bridge.close(wid) }
            }
            overlay.makeKeyAndOrderFront(nil)
            overlay.noteView.startBurn()
            self.foreignOverlays.append(overlay)
        }
    }

    // CG top-left window frame -> AppKit bottom-left screen frame (single display).
    private func toAppKitFrame(_ cg: CGRect, screen: NSScreen) -> CGRect {
        let h = screen.frame.height
        return CGRect(x: cg.origin.x, y: h - cg.origin.y - cg.height,
                      width: cg.width, height: cg.height)
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
        add(fxMenu, "Burn frontmost window", #selector(burnForeground), "b")
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
