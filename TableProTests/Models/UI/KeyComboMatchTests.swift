import AppKit
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("KeyCombo Event Matching")
struct KeyComboMatchTests {

    // MARK: - Helper

    private func makeEvent(
        keyCode: UInt16,
        characters: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!  // swiftlint:disable:this force_unwrapping
    }

    // MARK: - Bare Space

    @Test("Bare space combo matches space key event")
    func bareSpaceMatches() {
        let combo = KeyCombo(key: "space", isSpecialKey: true)
        let event = makeEvent(keyCode: 49, characters: " ")
        #expect(combo.matches(event))
    }

    @Test("Bare space combo does not match Cmd+Space")
    func bareSpaceRejectsCmdSpace() {
        let combo = KeyCombo(key: "space", isSpecialKey: true)
        let event = makeEvent(keyCode: 49, characters: " ", modifiers: .command)
        #expect(!combo.matches(event))
    }

    // MARK: - Modifier Combos

    @Test("Cmd+S matches correct event")
    func cmdSMatches() {
        let combo = KeyCombo(key: "s", command: true)
        let event = makeEvent(keyCode: 1, characters: "s", modifiers: .command)
        #expect(combo.matches(event))
    }

    @Test("Cmd+S does not match Cmd+Shift+S")
    func cmdSRejectsCmdShiftS() {
        let combo = KeyCombo(key: "s", command: true)
        let event = makeEvent(keyCode: 1, characters: "s", modifiers: [.command, .shift])
        #expect(!combo.matches(event))
    }

    @Test("Cmd+Shift+S matches correctly")
    func cmdShiftSMatches() {
        let combo = KeyCombo(key: "s", command: true, shift: true)
        let event = makeEvent(keyCode: 1, characters: "s", modifiers: [.command, .shift])
        #expect(combo.matches(event))
    }

    // MARK: - Special Keys

    @Test("Delete combo matches delete key event")
    func deleteMatches() {
        let combo = KeyCombo(key: "delete", command: true, isSpecialKey: true)
        let event = makeEvent(keyCode: 51, modifiers: .command)
        #expect(combo.matches(event))
    }

    @Test("Return combo matches return key event")
    func returnMatches() {
        let combo = KeyCombo(key: "return", command: true, isSpecialKey: true)
        let event = makeEvent(keyCode: 36, modifiers: .command)
        #expect(combo.matches(event))
    }

    @Test("Special key does not match wrong keyCode")
    func specialKeyRejectsWrongCode() {
        let combo = KeyCombo(key: "space", isSpecialKey: true)
        let event = makeEvent(keyCode: 36, characters: "")  // return, not space
        #expect(!combo.matches(event))
    }

    // MARK: - Cleared Combo

    @Test("Cleared combo does not match any event")
    func clearedComboNeverMatches() {
        let combo = KeyCombo.cleared
        let event = makeEvent(keyCode: 49, characters: " ")
        #expect(!combo.matches(event))
    }

    // MARK: - Bare Space Allowed in Recorder

    @Test("KeyCombo.init(from:) accepts bare space")
    func recorderAcceptsBareSpace() {
        let event = makeEvent(keyCode: 49, characters: " ")
        let combo = KeyCombo(from: event)
        #expect(combo != nil)
        #expect(combo?.key == "space")
        #expect(combo?.isSpecialKey == true)
        #expect(combo?.command == false)
    }

    @Test("KeyCombo.init(from:) rejects bare letter key")
    func recorderRejectsBareLetter() {
        let event = makeEvent(keyCode: 1, characters: "s")
        let combo = KeyCombo(from: event)
        #expect(combo == nil)
    }
}
