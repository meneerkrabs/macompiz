import Foundation

// Abstraction over the *privileged* window operations macompiz can't do itself
// (touching foreign apps' windows). The privileged code lives in a yabai-style
// scripting addition loaded into Dock with SIP partially disabled — macompiz only
// *talks* to it. We deliberately don't ship an injector; YabaiBridge drives an
// already-installed, audited yabai via its CLI.

struct BridgeWindow {
    let id: UInt32
    let pid: pid_t
    let frame: CGRect        // yabai/CG coords: top-left origin
    let app: String
    let title: String
}

protocol CompositorBridge {
    var name: String { get }
    var available: Bool { get }
    func listWindows() -> [BridgeWindow]
    func setOpacity(_ id: UInt32, _ alpha: Double)
    func close(_ id: UInt32)
}

/// Used when no privileged bridge is present. Foreign-window effects then render
/// as a visual-only overlay (the real window can't be hidden or closed).
struct NullBridge: CompositorBridge {
    let name = "none"
    let available = false
    func listWindows() -> [BridgeWindow] { [] }
    func setOpacity(_ id: UInt32, _ alpha: Double) {}
    func close(_ id: UInt32) {}
}

/// Drives an installed yabai (which carries the privileged scripting addition).
/// Requires the user to have set up yabai + SIP themselves; see docs/SIP.md.
struct YabaiBridge: CompositorBridge {
    let name = "yabai"
    let path: String

    init?() {
        let candidates = ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? YabaiBridge.which("yabai")
        guard let found else { return nil }
        path = found
    }

    var available: Bool {
        // reachable AND the scripting addition is live (query returns JSON)
        !run(["-m", "query", "--windows"]).out.isEmpty
    }

    func listWindows() -> [BridgeWindow] {
        let r = run(["-m", "query", "--windows"])
        guard let data = r.out.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { w in
            guard let id = (w["id"] as? NSNumber)?.uint32Value else { return nil }
            let f = w["frame"] as? [String: Any] ?? [:]
            let rect = CGRect(
                x: (f["x"] as? NSNumber)?.doubleValue ?? 0,
                y: (f["y"] as? NSNumber)?.doubleValue ?? 0,
                width: (f["w"] as? NSNumber)?.doubleValue ?? 0,
                height: (f["h"] as? NSNumber)?.doubleValue ?? 0)
            return BridgeWindow(id: id,
                                pid: pid_t((w["pid"] as? NSNumber)?.int32Value ?? 0),
                                frame: rect,
                                app: w["app"] as? String ?? "",
                                title: w["title"] as? String ?? "")
        }
    }

    func setOpacity(_ id: UInt32, _ alpha: Double) {
        _ = run(["-m", "window", "\(id)", "--opacity", String(format: "%.3f", alpha)])
    }

    func close(_ id: UInt32) {
        _ = run(["-m", "window", "\(id)", "--close"])
    }

    // MARK: process plumbing
    @discardableResult
    private func run(_ args: [String]) -> (out: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return ("", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }

    private static func which(_ tool: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", tool]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()
        return (out?.isEmpty == false) ? out : nil
    }
}

enum Bridges {
    /// Pick the best available privileged bridge, else a no-op.
    static func resolve() -> CompositorBridge {
        if let y = YabaiBridge(), y.available { return y }
        return NullBridge()
    }
}
