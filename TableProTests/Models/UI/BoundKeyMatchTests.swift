import AppKit
@testable import TablePro
import Testing

@Suite("BoundKey Event Matching")
struct BoundKeyMatchTests {
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

    // MARK: - Modifier Combos

    @Test("Cmd+S matches the correct event")
    func cmdSMatches() {
        let key = BoundKey(keyCode: KeyCode.s.rawValue, command: true)
        let event = makeEvent(keyCode: KeyCode.s.rawValue, characters: "s", modifiers: .command)
        #expect(key.matches(event))
    }

    @Test("Cmd+S does not match Cmd+Shift+S")
    func cmdSRejectsCmdShiftS() {
        let key = BoundKey(keyCode: KeyCode.s.rawValue, command: true)
        let event = makeEvent(keyCode: KeyCode.s.rawValue, characters: "s", modifiers: [.command, .shift])
        #expect(!key.matches(event))
    }

    // MARK: - Shifted Symbols (the bug the keyCode model fixes)

    @Test("Cmd+Shift+[ matches by key code even though the event reports the shifted glyph")
    func shiftedBracketMatchesByKeyCode() {
        let key = BoundKey(keyCode: KeyCode.leftBracket.rawValue, command: true, shift: true)
        // charactersIgnoringModifiers applies Shift, so the event reports "{", not "[".
        let event = makeEvent(keyCode: KeyCode.leftBracket.rawValue, characters: "{", modifiers: [.command, .shift])
        #expect(key.matches(event))
    }

    // MARK: - Layout Independence

    @Test("Cmd+C matches by key code regardless of the produced character")
    func layoutIndependentMatch() {
        let key = BoundKey(keyCode: KeyCode.c.rawValue, command: true)
        let event = makeEvent(keyCode: KeyCode.c.rawValue, characters: "ç", modifiers: .command)
        #expect(key.matches(event))
    }

    // MARK: - Special Keys

    @Test("Cmd+Delete matches the delete key event")
    func deleteMatches() {
        let key = BoundKey.special(.delete, command: true)
        let event = makeEvent(keyCode: KeyCode.delete.rawValue, modifiers: .command)
        #expect(key.matches(event))
    }

    @Test("Bare space matches a space key event")
    func bareSpaceMatches() {
        let key = BoundKey.special(.space)
        let event = makeEvent(keyCode: KeyCode.space.rawValue, characters: " ")
        #expect(key.matches(event))
    }

    @Test("Bare space does not match Cmd+Space")
    func bareSpaceRejectsCmdSpace() {
        let key = BoundKey.special(.space)
        let event = makeEvent(keyCode: KeyCode.space.rawValue, characters: " ", modifiers: .command)
        #expect(!key.matches(event))
    }

    // MARK: - Cleared

    @Test("Cleared combo does not match any event")
    func clearedNeverMatches() {
        let event = makeEvent(keyCode: KeyCode.space.rawValue, characters: " ")
        #expect(!BoundKey.cleared.matches(event))
    }

    // MARK: - Recorder Capture

    @Test("BoundKey(from:) accepts bare space")
    func recorderAcceptsBareSpace() {
        let event = makeEvent(keyCode: KeyCode.space.rawValue, characters: " ")
        let key = BoundKey(from: event)
        #expect(key != nil)
        #expect(key?.keyCode == KeyCode.space.rawValue)
        #expect(key?.command == false)
    }

    @Test("BoundKey(from:) rejects a bare letter key")
    func recorderRejectsBareLetter() {
        let event = makeEvent(keyCode: KeyCode.s.rawValue, characters: "s")
        #expect(BoundKey(from: event) == nil)
    }

    @Test("BoundKey(from:) records the physical key code")
    func recorderCapturesKeyCode() {
        let event = makeEvent(keyCode: KeyCode.k.rawValue, characters: "k", modifiers: .command)
        let key = BoundKey(from: event)
        #expect(key?.keyCode == KeyCode.k.rawValue)
        #expect(key?.command == true)
    }

    // MARK: - Function Keys

    @Test("BoundKey(from:) accepts a bare function key")
    func recorderAcceptsBareFunctionKey() {
        let key = BoundKey(from: makeEvent(keyCode: KeyCode.f5.rawValue))
        #expect(key != nil)
        #expect(key?.isFunctionKey == true)
        #expect(key?.hasModifier == false)
    }

    @Test("A function key renders its label and produces a key equivalent")
    func functionKeyDisplaysAndRegisters() {
        let key = BoundKey(keyCode: KeyCode.f5.rawValue)
        #expect(key.displayString == "F5")
        #expect(key.swiftUIKeyEquivalent != nil)
    }
}
