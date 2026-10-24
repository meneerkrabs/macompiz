import AppKit
import CoreGraphics

// Thin wrapper over the private SkyLight.framework (the modern name for the
// CoreGraphics/CGS window-server client API). Symbols are resolved with dlsym at
// runtime — nothing private is linked at build time, and every call runs in our
// own process with SIP enabled. This is the same surface yabai/Übersicht-style
// tools use for read-only space queries and (where macOS still allows it)
// switching the active Space. All of it is non-destructive and reversible; if a
// symbol is missing or the OS refuses the op, callers fall back gracefully.
final class SkyLight {
    static let shared = SkyLight()

    private typealias MainConnFn   = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias GetCurrentFn = @convention(c) (Int32, CFString) -> UInt64
    private typealias SetCurrentFn = @convention(c) (Int32, CFString, UInt64) -> Void

    let cid: Int32
    private let handle: UnsafeMutableRawPointer?
    private let copySpaces: CopySpacesFn?
    private let getCurrent: GetCurrentFn?
    private let setCurrent: SetCurrentFn?

    private init() {
        let h = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW)
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let h, let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        handle = h
        cid = sym("SLSMainConnectionID", MainConnFn.self)?() ?? 0
        copySpaces = sym("SLSCopyManagedDisplaySpaces", CopySpacesFn.self)
        getCurrent = sym("SLSManagedDisplayGetCurrentSpace", GetCurrentFn.self)
        setCurrent = sym("SLSManagedDisplaySetCurrentSpace", SetCurrentFn.self)
    }

    var available: Bool { handle != nil && cid != 0 && copySpaces != nil }
    /// Whether the OS still exposes programmatic space switching to us.
    var canSwitch: Bool { setCurrent != nil && getCurrent != nil }

    struct DisplaySpaces {
        let uuid: CFString
        let spaceIDs: [UInt64]
        let currentID: UInt64
        var currentIndex: Int { spaceIDs.firstIndex(of: currentID) ?? 0 }
    }

    private func mainDisplayUUID() -> CFString? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, u)
    }

    /// Enumerate the Spaces on the main display, with the active one marked.
    func mainDisplaySpaces() -> DisplaySpaces? {
        guard let copySpaces,
              let arr = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]],
              let uuid = mainDisplayUUID() else { return nil }
        let uuidStr = uuid as String

        func parse(_ disp: [String: Any]) -> DisplaySpaces {
            let spaces = disp["Spaces"] as? [[String: Any]] ?? []
            let ids = spaces.compactMap { s -> UInt64? in
                (s["ManagedSpaceID"] as? NSNumber)?.uint64Value
                    ?? (s["id64"] as? NSNumber)?.uint64Value
            }
            let cur = (disp["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber
            return DisplaySpaces(uuid: uuid, spaceIDs: ids, currentID: cur?.uint64Value ?? ids.first ?? 0)
        }

        if let match = arr.first(where: { ($0["Display Identifier"] as? String) == uuidStr }) {
            return parse(match)
        }
        return arr.first.map(parse)   // single-display machines label it "Main"
    }

    /// Attempt to make `spaceID` the active Space on the main display. Returns
    /// true only if the switch is observed to have taken effect.
    @discardableResult
    func setCurrentSpace(_ spaceID: UInt64) -> Bool {
        guard let setCurrent, let getCurrent, let uuid = mainDisplayUUID() else { return false }
        setCurrent(cid, uuid, spaceID)
        return getCurrent(cid, uuid) == spaceID
    }
}
