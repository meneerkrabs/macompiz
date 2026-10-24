import AppKit
import ApplicationServices

// Foreign-window control through the PUBLIC Accessibility API — no SIP changes,
// no scripting addition, no Recovery. AX can't do compositor opacity, so "hide"
// is implemented by moving the real window off-screen; "close" presses its close
// button. Combined with a captured-copy overlay this gives the full
// hide → animate → close flow with SIP enabled. Needs macompiz's own
// Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility).
final class AXBridge: CompositorBridge {
    let name = "accessibility"

    // AX element references stay valid after the window moves off-screen, but a
    // CGWindowList lookup of an off-screen window does not — so resolve each
    // window once (while on-screen) and reuse it for hide + close.
    private var cache: [CGWindowID: AXUIElement] = [:]

    // Resolve the private (non-SIP) symbol that maps an AX element to its
    // CGWindowID, so we can match the window we captured.
    private typealias GetWinFn = @convention(c)
        (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindowID: GetWinFn? = {
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        guard let p = dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(p, to: GetWinFn.self)
    }()

    var available: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(opt as CFDictionary)
    }

    func listWindows() -> [BridgeWindow] { [] }   // enumeration comes from SCK

    // setOpacity(0) -> move the real window off-screen (AX can't do opacity).
    func setOpacity(_ id: UInt32, _ alpha: Double) {
        guard alpha < 0.5, let win = element(for: CGWindowID(id)) else { return }
        var off = CGPoint(x: -20000, y: -20000)
        if let v = AXValueCreate(.cgPoint, &off) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
        }
    }

    func close(_ id: UInt32) {
        guard let win = element(for: CGWindowID(id)) else { return }
        var btn: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &btn) == .success,
           let b = btn, CFGetTypeID(b) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
        }
        cache[CGWindowID(id)] = nil
    }

    func diagnose(_ id: CGWindowID) -> String {
        var s = "getWindowID symbol present: \(AXBridge.getWindowID != nil)\n"
        guard let pid = AXBridge.pid(for: id) else { return s + "pid: NOT FOUND" }
        s += "pid: \(pid)\n"
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        s += "copyWindows err: \(err.rawValue)\n"
        let wins = (value as? [AXUIElement]) ?? []
        s += "ax windows: \(wins.count)\n"
        var matched = false
        if let getID = AXBridge.getWindowID {
            for w in wins {
                var wid: CGWindowID = 0
                if getID(w, &wid) == .success {
                    s += "  ax win id=\(wid)\(wid == id ? " <= MATCH" : "")\n"
                    if wid == id { matched = true }
                }
            }
        }
        s += "matched: \(matched)"
        return s
    }

    // MARK: lookup
    private func element(for id: CGWindowID) -> AXUIElement? {
        if let cached = cache[id] { return cached }
        guard let pid = AXBridge.pid(for: id), let getID = AXBridge.getWindowID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let wins = value as? [AXUIElement] else { return nil }
        for w in wins {
            var wid: CGWindowID = 0
            if getID(w, &wid) == .success, wid == id { cache[id] = w; return w }
        }
        return nil
    }

    private static func pid(for id: CGWindowID) -> pid_t? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let d = info.first,
              let pid = d[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return pid
    }
}
