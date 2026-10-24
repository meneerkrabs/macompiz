import AppKit
import ScreenCaptureKit

// System-wide "drag any window → it wobbles", SIP on. A CGEventTap watches global
// left-drags; when a drag starts on a window's titlebar we float a live-capture
// overlay running the wobble shader and let it follow the window macOS is moving.
// No injection: the real window is never deformed, just mirrored by the overlay.
final class WobbleDaemon {
    private var tap: CFMachPort?
    private let myPID = ProcessInfo.processInfo.processIdentifier

    // gesture state
    private var armedWindowID: CGWindowID?
    private var armedBounds: CGRect = .zero
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
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
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

    // Called from the event-tap callback (main runloop).
    func handle(_ type: CGEventType, _ event: CGEvent) {
        let p = event.location
        switch type {
        case .leftMouseDown:
            armForDrag(at: p)
        case .leftMouseDragged:
            if engaged { track(to: p) }
            else if armedWindowID != nil, hypot(p.x - startPoint.x, p.y - startPoint.y) > 6 {
                engage()
            }
        case .leftMouseUp:
            end()
        default:
            break
        }
    }

    private func armForDrag(at p: CGPoint) {
        armedWindowID = nil
        guard let (id, bounds) = WobbleDaemon.windowUnder(p, excludingPID: myPID) else { return }
        // only treat the top strip (titlebar) as a window drag, not content drags
        guard p.y - bounds.minY < 32 else { return }
        armedWindowID = id
        armedBounds = bounds
        startPoint = p
        lastPoint = p
        lastTime = CACurrentMediaTime()
    }

    private func engage() {
        guard let id = armedWindowID else { return }
        engaged = true
        let bounds = armedBounds
        let cap = LiveCapture()
        capture = cap
        let ov = WobbleOverlay(frame: WobbleDaemon.nsFrame(from: bounds), capture: cap)
        overlay = ov
        ov.orderFront(nil)
        print("wobble: engaged window \(id) at \(WobbleDaemon.nsFrame(from: bounds))")
        Task { @MainActor in
            guard let scw = await ScreenCapture.foreignWindows()
                    .first(where: { CGWindowID($0.windowID) == id }) else {
                print("wobble: no SCWindow match for \(id)"); return
            }
            await cap.start(window: scw)
            print("wobble: live capture started, texture=\(cap.texture != nil)")
        }
    }

    private func track(to p: CGPoint) {
        let now = CACurrentMediaTime()
        let dt = Float(now - lastTime)
        let dx = p.x - lastPoint.x, dy = p.y - lastPoint.y
        overlay?.nudge(dx: dx, dy: -dy)          // CG y-down -> NS y-up
        overlay?.view.feed(dx: dx, dy: dy, dt: dt)
        lastPoint = p
        lastTime = now
    }

    private func end() {
        engaged = false
        armedWindowID = nil
        capture?.stop()
        capture = nil
        overlay?.orderOut(nil)
        overlay = nil
    }

    // MARK: helpers

    // Topmost normal window containing the point, excluding our own.
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

    // CG global (top-left) rect -> AppKit (bottom-left) frame.
    static func nsFrame(from cg: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? cg.maxY
        return CGRect(x: cg.minX, y: h - cg.maxY, width: cg.width, height: cg.height)
    }
}

private func wobbleTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                               event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<WobbleDaemon>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}
