//
//  RecentTabSwitcherKeyCommand.swift
//  TablePro
//

import AppKit

/// What a key pressed while the switch is held does to it.
internal enum RecentTabSwitcherKeyCommand: Equatable {
    case step(RecentTabSwitchDirection)
    case commit
    case cancel
    /// Swallowed without effect. A key typed mid-switch belongs to neither the switcher nor the
    /// editor behind it, which would otherwise receive it with the modifier still down.
    case ignore

    private static let chordModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// Either binding with Shift flipped walks the other way, the way Shift reverses Command-Tab, so
    /// the reverse direction works even for a user who only bound the forward command.
    ///
    /// The bindings are read first, so a chord bound to Control-Return or Control-Escape steps like
    /// any other rather than committing or cancelling the switch it started.
    internal static func resolve(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        forward: BoundKey?,
        backward: BoundKey?
    ) -> RecentTabSwitcherKeyCommand {
        let pressed = modifiers.intersection(chordModifiers)
        let bindings: [(key: BoundKey?, direction: RecentTabSwitchDirection)] = [
            (forward, .forward),
            (backward, .backward)
        ]
        for binding in bindings {
            guard let key = binding.key, !key.isCleared, key.keyCode == keyCode,
                  pressed.subtracting(.shift) == key.modifierFlags.subtracting(.shift)
            else { continue }
            return .step(pressed.contains(.shift) == key.shift ? binding.direction : binding.direction.reversed)
        }

        switch KeyCode(rawValue: keyCode) {
        case .escape:
            return .cancel
        case .return, .enter:
            return .commit
        case .upArrow:
            return .step(.backward)
        case .downArrow:
            return .step(.forward)
        default:
            return .ignore
        }
    }

    /// The modifiers a keyboard-started switch waits on: whatever the chord held apart from Shift,
    /// which only reverses. Empty for a switch started from the menu with the pointer, or from a
    /// binding with no modifier, and such a switch has nothing to wait for.
    internal static func heldModifiers(of event: NSEvent?) -> NSEvent.ModifierFlags {
        guard let event, event.type == .keyDown else { return [] }
        return event.modifierFlags.intersection([.command, .option, .control])
    }

    /// Whether a modifier change ends the switch: any held modifier coming up commits, the way
    /// letting go of Command commits the app switcher.
    internal static func releases(_ modifiers: NSEvent.ModifierFlags, held: NSEvent.ModifierFlags) -> Bool {
        !modifiers.intersection(.deviceIndependentFlagsMask).isSuperset(of: held)
    }
}
