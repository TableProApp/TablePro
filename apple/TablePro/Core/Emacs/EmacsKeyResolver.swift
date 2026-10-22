//
//  EmacsKeyResolver.swift
//  TablePro
//

import AppKit
import Carbon.HIToolbox

enum EmacsMotion: Equatable {
    case forwardChar
    case backwardChar
    case nextLine
    case previousLine
    case beginningOfLine
    case endOfLine
    case forwardWord
    case backwardWord

    var selector: Selector {
        switch self {
        case .forwardChar: #selector(NSResponder.moveForward(_:))
        case .backwardChar: #selector(NSResponder.moveBackward(_:))
        case .nextLine: #selector(NSResponder.moveDown(_:))
        case .previousLine: #selector(NSResponder.moveUp(_:))
        case .beginningOfLine: #selector(NSResponder.moveToBeginningOfParagraph(_:))
        case .endOfLine: #selector(NSResponder.moveToEndOfParagraph(_:))
        case .forwardWord: #selector(NSResponder.moveWordForward(_:))
        case .backwardWord: #selector(NSResponder.moveWordBackward(_:))
        }
    }

    var extendingSelector: Selector {
        switch self {
        case .forwardChar: #selector(NSResponder.moveForwardAndModifySelection(_:))
        case .backwardChar: #selector(NSResponder.moveBackwardAndModifySelection(_:))
        case .nextLine: #selector(NSResponder.moveDownAndModifySelection(_:))
        case .previousLine: #selector(NSResponder.moveUpAndModifySelection(_:))
        case .beginningOfLine: #selector(NSResponder.moveToBeginningOfParagraphAndModifySelection(_:))
        case .endOfLine: #selector(NSResponder.moveToEndOfParagraphAndModifySelection(_:))
        case .forwardWord: #selector(NSResponder.moveWordForwardAndModifySelection(_:))
        case .backwardWord: #selector(NSResponder.moveWordBackwardAndModifySelection(_:))
        }
    }
}

enum EmacsCommand: Equatable {
    case move(EmacsMotion)
    case killLine
    case killWord
    case backwardKillWord
    case killRegion
    case copyRegion
    case yank
    case yankPop
    case setMark
    case quit
}

struct EmacsKeystroke {
    let keyCode: Int
    let charactersIgnoringModifiers: String
    let modifiers: NSEvent.ModifierFlags
}

extension EmacsKeystroke {
    init(event: NSEvent) {
        self.init(
            keyCode: Int(event.keyCode),
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            modifiers: event.modifierFlags
        )
    }
}

enum EmacsKeyResolver {
    private static let controlKeys: [String: EmacsCommand] = [
        "a": .move(.beginningOfLine),
        "e": .move(.endOfLine),
        "f": .move(.forwardChar),
        "b": .move(.backwardChar),
        "n": .move(.nextLine),
        "p": .move(.previousLine),
        "k": .killLine,
        "y": .yank,
        "w": .killRegion,
        "g": .quit,
        " ": .setMark
    ]

    // Option is Meta only for these keys, so Option still types every other character the layout puts on it.
    private static let metaKeys: [String: EmacsCommand] = [
        "f": .move(.forwardWord),
        "b": .move(.backwardWord),
        "d": .killWord,
        "y": .yankPop,
        "w": .copyRegion
    ]

    private static let regionArrows: [Int: EmacsCommand] = [
        kVK_LeftArrow: .move(.backwardChar),
        kVK_RightArrow: .move(.forwardChar),
        kVK_UpArrow: .move(.previousLine),
        kVK_DownArrow: .move(.nextLine)
    ]

    static func command(for keystroke: EmacsKeystroke, markActive: Bool) -> EmacsCommand? {
        let modifiers = keystroke.modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        let key = keystroke.charactersIgnoringModifiers.lowercased()

        switch modifiers {
        case .control:
            if keystroke.keyCode == kVK_Space { return .setMark }
            return controlKeys[key]
        case [.control, .shift]:
            return key == "@" ? .setMark : nil
        case .option:
            if keystroke.keyCode == kVK_Delete { return .backwardKillWord }
            return metaKeys[key]
        case []:
            // With an active region the arrows extend it, as every motion does.
            return markActive ? regionArrows[keystroke.keyCode] : nil
        default:
            return nil
        }
    }
}
