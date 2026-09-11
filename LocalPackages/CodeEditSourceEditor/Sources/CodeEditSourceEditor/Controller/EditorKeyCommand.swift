//
//  EditorKeyCommand.swift
//  CodeEditSourceEditor
//

import AppKit
import Carbon.HIToolbox

internal enum EditorKeyCommand: Equatable {
    case toggleComment
    case outdent
    case indent
    case duplicateLine
    case deleteLine
    case escape
    case showCompletions
    case jumpToDefinition
    case moveLinesUp
    case moveLinesDown

    private static let command = NSEvent.ModifierFlags.command
    private static let control = NSEvent.ModifierFlags.control
    private static let option = NSEvent.ModifierFlags.option
    private static let noModifiers = NSEvent.ModifierFlags()

    internal init?(event: NSEvent, modifierFlags: NSEvent.ModifierFlags) {
        let resolved = Self.characterCommand(modifierFlags: modifierFlags, characters: event.charactersIgnoringModifiers)
            ?? Self.keyCodeCommand(modifierFlags: modifierFlags.subtracting(.numericPad), keyCode: Int(event.keyCode))
        guard let resolved else { return nil }
        self = resolved
    }

    internal var isCommandChord: Bool {
        switch self {
        case .toggleComment, .outdent, .indent, .duplicateLine, .deleteLine, .jumpToDefinition:
            return true
        case .escape, .showCompletions, .moveLinesUp, .moveLinesDown:
            return false
        }
    }

    private static func characterCommand(
        modifierFlags: NSEvent.ModifierFlags,
        characters: String?
    ) -> EditorKeyCommand? {
        switch (modifierFlags, characters) {
        case (command, "/"):
            return .toggleComment
        case (command, "["):
            return .outdent
        case (command, "]"):
            return .indent
        case ([command, .shift], "D"):
            return .duplicateLine
        case ([command, .shift], "K"):
            return .deleteLine
        case (noModifiers, "\u{1b}"):
            return .escape
        case (control, " "):
            return .showCompletions
        case ([command, control], "j"):
            return .jumpToDefinition
        default:
            return nil
        }
    }

    private static func keyCodeCommand(modifierFlags: NSEvent.ModifierFlags, keyCode: Int) -> EditorKeyCommand? {
        switch (modifierFlags, keyCode) {
        case (option, kVK_UpArrow):
            return .moveLinesUp
        case (option, kVK_DownArrow):
            return .moveLinesDown
        default:
            return nil
        }
    }
}
