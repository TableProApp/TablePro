import Carbon.HIToolbox
@testable import TablePro
import Testing

struct SystemHotkeyCheckerTests {
    @Test("A Globe chord is not the same chord without Globe, so it reserves nothing")
    func fnChordReservesNothing() {
        let globeControlF = controlKey | kEventKeyModifierFnMask
        #expect(SystemHotkeyChecker.boundKey(code: Int(KeyCode.f.rawValue), modifiers: globeControlF) == nil)
    }

    @Test("A chord without Globe keeps its modifiers")
    func plainChordKeepsModifiers() {
        #expect(
            SystemHotkeyChecker.boundKey(code: Int(KeyCode.f.rawValue), modifiers: controlKey)
                == .special(.f, control: true)
        )
        #expect(
            SystemHotkeyChecker.boundKey(code: Int(KeyCode.space.rawValue), modifiers: cmdKey | shiftKey | optionKey)
                == .special(.space, command: true, shift: true, option: true)
        )
    }

    @Test("A key code outside the keyboard range is skipped", arguments: [-1, 65535, 70000])
    func outOfRangeCodeSkipped(code: Int) {
        #expect(SystemHotkeyChecker.boundKey(code: code, modifiers: cmdKey) == nil)
    }
}
