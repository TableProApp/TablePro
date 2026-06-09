//
//  SystemHotkeyChecker.swift
//  TablePro
//
//  Reports the user's live, enabled macOS system shortcuts so the recorder can
//  refuse combos the system already owns. Reads the same data as
//  System Settings > Keyboard > Shortcuts via CopySymbolicHotKeys, so it adapts
//  to the user's configuration instead of relying on a hand-maintained list.
//

import AppKit
import Carbon.HIToolbox

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
                  code >= 0, code < Int(UInt16.max) else {
                continue
            }
            result.insert(BoundKey(
                keyCode: UInt16(code),
                command: modifiers & cmdKey != 0,
                shift: modifiers & shiftKey != 0,
                option: modifiers & optionKey != 0,
                control: modifiers & controlKey != 0
            ))
        }
        return result
    }
}
