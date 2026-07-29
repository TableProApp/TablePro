//
//  ShortcutConflictResolver.swift
//  TablePro
//
//  Resolves what a recorded shortcut would collide with: a macOS system
//  shortcut, a built-in editor command, or another customizable action in an
//  overlapping context.
//

import Foundation

enum ShortcutConflict: Equatable {
    case none
    case systemReserved
    case reserved(String)
    case otherAction(ShortcutAction)
}

@MainActor
enum ShortcutConflictResolver {
    static func resolve(_ key: BoundKey, for action: ShortcutAction, in settings: KeyboardSettings) -> ShortcutConflict {
        guard !key.isCleared else { return .none }

        if SystemHotkeyChecker.shared.isReserved(key) {
            return .systemReserved
        }

        if let name = ShortcutAction.reservedConflict(for: key, context: action.context) {
            return .reserved(name)
        }

        if let other = settings.findConflict(for: key, excluding: action) {
            return .otherAction(other)
        }

        return .none
    }
}
