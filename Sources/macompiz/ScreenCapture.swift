import AppKit
import ScreenCaptureKit
import CoreGraphics

// One-shot capture of the current desktop via ScreenCaptureKit, used as a real
// cube face. SCScreenshotManager (macOS 14+) hands back a CGImage directly, so
// no SCStream lifecycle is needed. Needs the Screen Recording permission; on the
// first attempt macOS shows the prompt. If it's denied or unavailable the caller
// falls back to a synthetic space, so the cube still works.
enum ScreenCapture {

    /// Captures the display that contains the given screen. `exclude` lets the
    /// caller drop its own overlay windows from the shot by CGWindowID.
    static func capture(screen: NSScreen, exclude: [CGWindowID] = []) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)

            let targetID = screen.displayID
            let display = content.displays.first { $0.displayID == targetID }
                ?? content.displays.first
            guard let display else { return nil }

            let windows = content.windows.filter { exclude.contains(CGWindowID($0.windowID)) }
            let filter = SCContentFilter(display: display, excludingWindows: windows)

            let cfg = SCStreamConfiguration()
            cfg.width = display.width
            cfg.height = display.height
            cfg.showsCursor = false
            cfg.capturesAudio = false

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg)
        } catch {
            FileHandle.standardError.write(
                Data("macompiz: screen capture unavailable (\(error.localizedDescription))\n".utf8))
            return nil
        }
    }

    /// On-screen, titled windows of *other* apps (ours excluded), front-to-back.
    static func foreignWindows() async -> [SCWindow] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            return content.windows.filter { w in
                w.isOnScreen && (w.title?.isEmpty == false)
                    && w.owningApplication?.processID != myPID
                    && w.frame.width > 80 && w.frame.height > 60
            }
        } catch { return [] }
    }

    /// Capture a single window's current pixels (SIP-friendly, read-only).
    static func captureWindow(_ window: SCWindow) async -> CGImage? {
        do {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let cfg = SCStreamConfiguration()
            cfg.width = Int(window.frame.width * 2)
            cfg.height = Int(window.frame.height * 2)
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg)
        } catch {
            return nil
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }
}
