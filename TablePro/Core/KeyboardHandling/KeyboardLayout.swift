//
//  KeyboardLayout.swift
//  TablePro
//
//  Resolves between hardware key codes and their base (unshifted) characters
//  for the active ASCII-capable keyboard layout. Built once and cached.
//
//  The cache is a `static let`, so Swift's one-time initializer builds it
//  exactly once even under concurrent first access. Every Carbon call here is a
//  pure read (`TISCopyCurrentASCIICapableKeyboardLayoutInputSource` copies,
//  `UCKeyTranslate` and `LMGetKbdType` only read), so the build is safe off the
//  main thread. This matters because Swift Testing exercises it from parallel
//  test tasks; pinning it to the main actor would break those.
//

import AppKit
import Carbon.HIToolbox

enum KeyboardLayout {
    static func baseCharacter(for keyCode: UInt16) -> Character? {
        maps.keyCodeToCharacter[keyCode] ?? KeyCode(rawValue: keyCode)?.usBaseCharacter
    }

    static func keyCode(for character: Character) -> UInt16? {
        let lowered = Character(character.lowercased())
        return maps.characterToKeyCode[lowered] ?? usFallback[lowered]
    }

    private static let maps = buildMaps()

    private static let usFallback: [Character: UInt16] = {
        var result: [Character: UInt16] = [:]
        for raw in UInt16(0)...127 {
            guard let character = KeyCode(rawValue: raw)?.usBaseCharacter else { continue }
            if result[character] == nil { result[character] = raw }
        }
        return result
    }()

    private static func buildMaps() -> (keyCodeToCharacter: [UInt16: Character], characterToKeyCode: [Character: UInt16]) {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return ([:], [:])
        }
        let layoutData = unsafeBitCast(layoutPointer, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return ([:], [:]) }
        let keyboardLayout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())

        var toCharacter: [UInt16: Character] = [:]
        var toKeyCode: [Character: UInt16] = [:]

        for keyCode in UInt16(0)...127 {
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                keyboardLayout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length == 1 else { continue }
            let scalarString = String(utf16CodeUnits: characters, count: length)
            guard let character = scalarString.first, !character.isWhitespace, !character.isNewline else { continue }
            toCharacter[keyCode] = character
            if toKeyCode[character] == nil { toKeyCode[character] = keyCode }
        }
        return (toCharacter, toKeyCode)
    }
}
