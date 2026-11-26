import AppKit
import Carbon.HIToolbox

// Reads the live data System Settings > Keyboard > Shortcuts shows, so it follows the user's own setup, not a fixed list.
@MainActor
final class SystemHotkeyChecker {
    static let shared = SystemHotkeyChecker()

    private var reserved: Set<BoundKey> = []
    private var hasLoaded = false

    private init() {}

    func isReserved(_ key: BoundKey) -> Bool {
        guard !key.isCleared else { return false }
        if !hasLoaded { reload() }
        return reserved.contains(key)
    }

    func reload() {
        hasLoaded = true
        reserved = Self.loadSystemHotkeys()
    }

    // BoundKey has no Globe flag, so a Globe chord such as window tiling's Globe-Control-F would read as plain Control-F.
    nonisolated static func boundKey(code: Int, modifiers: Int) -> BoundKey? {
        guard code >= 0, code < Int(UInt16.max), modifiers & kEventKeyModifierFnMask == 0 else { return nil }
        return BoundKey(
            keyCode: UInt16(code),
            command: modifiers & cmdKey != 0,
            shift: modifiers & shiftKey != 0,
            option: modifiers & optionKey != 0,
            control: modifiers & controlKey != 0
        )
    }

    private static func loadSystemHotkeys() -> Set<BoundKey> {
        var hotkeysRef: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&hotkeysRef) == noErr,
              let entries = hotkeysRef?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }

        var result: Set<BoundKey> = []
        for entry in entries {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int,
                  let key = boundKey(code: code, modifiers: modifiers) else {
                continue
            }
            result.insert(key)
        }
        return result
    }
}
