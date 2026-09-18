//
//  VimKeyRouteResolver.swift
//  TablePro
//

import AppKit

enum VimKeyRoute: Equatable {
    case textView
    case engine(Character)
    case discard
}

struct VimKeystroke {
    let characters: String
    let charactersIgnoringModifiers: String
    let modifiers: NSEvent.ModifierFlags
    let isKeypadEnter: Bool
}

enum VimKeyRouteResolver {
    private static let escape: Character = "\u{1B}"
    private static let backtab: Character = "\u{19}"
    private static let keysControlLeavesToTheTextView: Set<Character> = ["\t", backtab, " "]
    private static let forwardDelete: UInt32 = 0xF728
    private static let functionKeyRange: ClosedRange<UInt32> = 0xF700...0xF8FF
    private static let arrowMotions: [UInt32: Character] = [
        0xF700: "k",
        0xF701: "j",
        0xF702: "h",
        0xF703: "l"
    ]

    static func route(_ keystroke: VimKeystroke, in mode: VimMode) -> VimKeyRoute {
        let modifiers = keystroke.modifiers.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command) else { return .textView }
        guard let typed = keystroke.characters.first else {
            return mode.isInsert ? .textView : .discard
        }
        let character: Character = keystroke.isKeypadEnter ? "\r" : typed
        if let functionKey = functionKeyValue(of: character) {
            return routeFunctionKey(functionKey, modifiers: modifiers, in: mode)
        }
        let key = keystroke.charactersIgnoringModifiers.first
        if let key, isPlainControlChord(modifiers), keysControlLeavesToTheTextView.contains(key) {
            return .textView
        }
        if key == backtab {
            return mode == .insert ? .textView : .discard
        }
        if modifiers.contains(.control) {
            return routeControlChord(character, modifiers: modifiers, in: mode)
        }
        if modifiers.contains(.option), mode == .insert {
            return .textView
        }
        return .engine(character)
    }

    private static func isPlainControlChord(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.control) && !modifiers.contains(.option)
    }

    private static func routeFunctionKey(
        _ functionKey: UInt32,
        modifiers: NSEvent.ModifierFlags,
        in mode: VimMode
    ) -> VimKeyRoute {
        guard !mode.isInsert else { return .textView }
        let isChord = modifiers.contains(.option) || modifiers.contains(.control)
        if functionKey == forwardDelete {
            return isChord || mode.isCommandLine ? .discard : .engine("x")
        }
        guard let motion = arrowMotions[functionKey], !isChord else { return .textView }
        return mode.isCommandLine ? .discard : .engine(motion)
    }

    private static func routeControlChord(
        _ character: Character,
        modifiers: NSEvent.ModifierFlags,
        in mode: VimMode
    ) -> VimKeyRoute {
        if mode.isInsert {
            let claimed = isClaimedInInsertModes(character, in: mode)
            return claimed && !modifiers.contains(.option) ? .engine(character) : .textView
        }
        let producesInput = modifiers.contains(.option) || VimEngine.isUnwritableControl(character)
        return producesInput ? .engine(character) : .textView
    }

    private static func isClaimedInInsertModes(_ character: Character, in mode: VimMode) -> Bool {
        if character == escape || VimInsertControl(rawValue: character) != nil { return true }
        return mode == .replace && VimEngine.backspaceCharacters.contains(character)
    }

    private static func functionKeyValue(of character: Character) -> UInt32? {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return nil }
        return functionKeyRange.contains(scalar.value) ? scalar.value : nil
    }
}
