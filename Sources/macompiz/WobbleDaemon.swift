import AppKit
import ScreenCaptureKit

// System-wide "drag any window → it wobbles", SIP on. A CGEventTap watches global
// left-drags; when a drag starts on a window's titlebar the daemon takes over:
// it hides the real window off-screen (Accessibility), consumes the drag events so
// macOS doesn't fight it, and floats a live-capture overlay running the wobble
// shader that follows the cursor. On release the real window is placed where the
// overlay ended. No injection — the real window is mirrored, never deformed.
final class WobbleDaemon {
    private var tap: CFMachPort?
    private let myPID = ProcessInfo.processInfo.processIdentifier
    private let ax = AXBridge()

    // gesture state
    private var armedWindowID: CGWindowID?
    private var armedBounds: CGRect = .zero       // CG top-left frame at mouseDown
    private var startPoint: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var lastTime = CACurrentMediaTime()
    private var engaged = false

    private var capture: LiveCapture?
    private var overlay: WobbleOverlay?

    func start() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: wobbleTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Returns true to CONSUME the event (so macOS doesn't also act on it).
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let p = event.location
        switch type {
        case .leftMouseDown:
            armForDrag(at: p)
            return false                              // let the click focus/raise

        case .leftMouseDragged:
            guard armedWindowID != nil else { return false }
            if !engaged, hypot(p.x - startPoint.x, p.y - startPoint.y) > 6 { engage() }
            if engaged { track(to: p) }
            return true                               // we own the drag now

        case .leftMouseUp:
            guard armedWindowID != nil else { return false }
            let wasEngaged = engaged
            end()
            return wasEngaged

        default:
            return false
        }
    }

    private func armForDrag(at p: CGPoint) {
        armedWindowID = nil
        guard let (id, bounds) = WobbleDaemon.windowUnder(p, excludingPID: myPID) else { return }
        guard p.y - bounds.minY < 32 else { return }  // titlebar strip only
        armedWindowID = id
        armedBounds = bounds
        startPoint = p
        lastPoint = p
        lastTime = CACurrentMediaTime()
    }

    private func engage() {
        guard let id = armedWindowID else { return }
        engaged = true
        let nsFrame = WobbleDaemon.nsFrame(from: armedBounds)
        let cap = LiveCapture()
        capture = cap
        let ov = WobbleOverlay(frame: nsFrame, capture: cap)
        overlay = ov
        ov.orderFront(nil)
        let hideY = armedBounds.minY
        Task { @MainActor in
            guard let scw = await ScreenCapture.foreignWindows()
                    .first(where: { CGWindowID($0.windowID) == id }) else { return }
            await cap.start(window: scw)
            // hide the real window only once the live copy has a frame (seamless)
            for _ in 0..<80 {
                if cap.texture != nil { break }
                try? await Task.sleep(nanoseconds: 6_000_000)
            }
            if self.engaged, self.armedWindowID == id {
                self.ax.move(id, toCG: CGPoint(x: -30000, y: hideY))
            }
        }
    }

    private func track(to p: CGPoint) {
        let now = CACurrentMediaTime()
        let dt = Float(now - lastTime)
        let dx = p.x - lastPoint.x, dy = p.y - lastPoint.y
        overlay?.nudge(dx: dx, dy: -dy)               // CG y-down -> NS y-up
        overlay?.view.feed(dx: dx, dy: dy, dt: dt)
        lastPoint = p
        lastTime = now
    }

    private func end() {
        if engaged, let id = armedWindowID, let ov = overlay {
            // place the real window where the overlay ended (NS -> CG top-left)
            let h = NSScreen.screens.first?.frame.height ?? 0
            let f = ov.frame
            ax.move(id, toCG: CGPoint(x: f.minX, y: h - f.maxY))
            ax.forget(id)
        }
        engaged = false
        armedWindowID = nil
        capture?.stop(); capture = nil
        overlay?.orderOut(nil); overlay = nil
    }

    // MARK: helpers

    static func windowUnder(_ p: CGPoint, excludingPID pid: pid_t) -> (CGWindowID, CGRect)? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != pid,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0,
                              width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if rect.contains(p) { return (id, rect) }
        }
        return nil
    }

    static func nsFrame(from cg: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? cg.maxY
        return CGRect(x: cg.minX, y: h - cg.maxY, width: cg.width, height: cg.height)
    }
}

private func wobbleTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                               event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let consume = Unmanaged<WobbleDaemon>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
    return consume ? nil : Unmanaged.passUnretained(event)
}
