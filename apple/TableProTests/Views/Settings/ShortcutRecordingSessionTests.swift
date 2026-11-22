import AppKit
import Foundation
@testable import TablePro
import Testing

struct ShortcutRecordingClassifyTests {
    // kVK_Command, the key code a Command flagsChanged event carries.
    private static let commandKeyCode: UInt16 = 55

    private func step(
        _ keyCode: KeyCode,
        _ flags: NSEvent.ModifierFlags = [],
        for action: ShortcutAction = .refresh,
        isRepeat: Bool = false,
        inWindow: Bool = true
    ) throws -> ShortcutRecordingStep {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: isRepeat,
            keyCode: keyCode.rawValue
        ))
        return classify(event, for: action, inWindow: inWindow)
    }

    private func click(
        _ type: NSEvent.EventType = .leftMouseDown,
        inWindow: Bool = true,
        hitsButton: Bool = false
    ) throws -> ShortcutRecordingStep {
        let event = try #require(NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        return classify(event, inWindow: inWindow, hitsButton: hitsButton)
    }

    private func classify(
        _ event: NSEvent,
        for action: ShortcutAction = .refresh,
        inWindow: Bool = true,
        hitsButton: Bool = false
    ) -> ShortcutRecordingStep {
        ShortcutRecordingSession.classify(
            event,
            recording: action,
            isInRecordingWindow: inWindow,
            hitsRecordingButton: hitsButton
        )
    }

    @Test("An event for another window, or a window that is not key, passes untouched")
    func otherWindowPasses() throws {
        #expect(try step(.w, .command, inWindow: false) == .pass)
        #expect(try click(inWindow: false) == .pass)
    }

    @Test("A click on the recording button passes, so its own action stops recording")
    func clickOnOwnButtonPasses() throws {
        #expect(try click(hitsButton: true) == .pass)
    }

    @Test("Any other click cancels and still reaches its target", arguments: [
        NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown,
    ])
    func otherClickCancels(type: NSEvent.EventType) throws {
        #expect(try click(type) == .cancelAndPass)
    }

    @Test("Held modifiers are shown and swallowed, without Caps Lock or Fn")
    func modifiersAreHeld() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.command, .shift, .capsLock, .function],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: Self.commandKeyCode
        ))
        #expect(classify(event) == .holdModifiers([.command, .shift]))
    }

    @Test("Key repeat is swallowed")
    func repeatIsSwallowed() throws {
        #expect(try step(.j, .command, isRepeat: true) == .swallow)
    }

    @Test("Tab and Shift-Tab cancel and move focus on")
    func tabLeaves() throws {
        #expect(try step(.tab) == .cancelAndPass)
        #expect(try step(.tab, .shift) == .cancelAndPass)
    }

    @Test("Control-Tab is recorded")
    func controlTabIsRecorded() throws {
        #expect(try step(.tab, .control) == .capture(.special(.tab, control: true)))
    }

    @Test("Escape cancels on every row, Option-Escape is a chord")
    func escapeCancels() throws {
        #expect(try step(.escape) == .cancel)
        #expect(try step(.escape, for: .previewFKReference) == .cancel)
        #expect(try step(.escape, .option, for: .addRow) == .capture(.special(.escape, option: true)))
    }

    @Test("Delete removes the shortcut, a modified Delete is a chord")
    func deleteRemoves() throws {
        #expect(try step(.delete) == .remove)
        #expect(try step(.delete, .shift, for: .addRow) == .capture(.special(.delete, shift: true)))
    }

    @Test("A bare Forward Delete is refused unless the action allows a bare key")
    func bareForwardDelete() throws {
        #expect(try step(.forwardDelete, for: .delete) == .refuse(ShortcutAction.delete.modifierRefusal))
        #expect(try step(.forwardDelete, for: .previewFKReference) == .capture(.special(.forwardDelete)))
    }

    @Test("Command-W is captured instead of closing the window")
    func commandWIsCaptured() throws {
        #expect(try step(.w, .command) == .capture(.character("w", command: true)))
    }

    @Test("Option or Shift alone on a letter is refused with the reason")
    func optionLetterIsRefused() throws {
        #expect(try step(.e, .option) == .refuse(String(localized: "Add ⌘ or ⌃ to this shortcut.")))
        #expect(
            try step(.e, .option, for: .previewFKReference)
                == .refuse(String(localized: "Use ⌘ or ⌃, Space, or a function key."))
        )
        #expect(try step(.return) == .refuse(ShortcutAction.refresh.modifierRefusal))
    }

    @Test("A bare Space records only for Preview FK Reference")
    func bareSpace() throws {
        #expect(try step(.space, for: .previewFKReference) == .capture(.special(.space)))
        #expect(try step(.space) == .refuse(ShortcutAction.refresh.modifierRefusal))
    }
}

@MainActor
struct ShortcutRecordingSessionTests {
    @MainActor
    private final class Signals {
        var messages: [String] = []
    }

    private let free = BoundKey.character("j", command: true, option: true, control: true)

    private func makeSession(
        _ settings: KeyboardSettings = .default
    ) -> (session: ShortcutRecordingSession, slice: SettingsSlice<KeyboardSettings>, signals: Signals) {
        let slice = SettingsSlice(settings)
        let signals = Signals()
        let session = ShortcutRecordingSession(keyboard: slice) { signals.messages.append($0) }
        return (session, slice, signals)
    }

    @Test("Toggling the recording row twice starts and stops recording")
    func toggleStartsAndStops() {
        let (session, _, _) = makeSession()
        session.toggle(.refresh)
        #expect(session.recording == .refresh)
        session.toggle(.newTab)
        #expect(session.recording == .newTab)
        session.toggle(.newTab)
        #expect(session.recording == nil)
    }

    @Test("Cancel drops the held modifiers")
    func cancelClearsModifiers() {
        let (session, _, _) = makeSession()
        session.begin(.refresh)
        #expect(session.perform(.holdModifiers([.command, .option]), for: .refresh))
        #expect(session.heldModifiers == [.command, .option])
        session.cancel()
        #expect(session.heldModifiers.isEmpty)
        #expect(session.recording == nil)
    }

    @Test("A free chord is assigned and recording ends")
    func freeChordIsAssigned() {
        let (session, slice, signals) = makeSession()
        session.begin(.refresh)
        #expect(session.perform(.capture(free), for: .refresh))
        #expect(slice.value.boundKey(for: .refresh) == free)
        #expect(session.recording == nil)
        #expect(signals.messages.isEmpty)
    }

    @Test("Recording the default again stores nothing")
    func defaultChordStoresNothing() {
        let (session, slice, _) = makeSession()
        session.begin(.refresh)
        session.perform(.capture(.character("r", command: true)), for: .refresh)
        #expect(slice.value == .default)
    }

    @Test("A reserved chord is refused inline and recording stays armed")
    func reservedChordIsRefused() {
        let (session, slice, signals) = makeSession()
        session.begin(.refresh)
        session.perform(.capture(.character("q", command: true)), for: .refresh)
        let message = String(format: String(localized: "%@ is used by “%@”."), "⌘Q", String(localized: "Quit TablePro"))
        #expect(session.recording == .refresh)
        #expect(session.feedback == ShortcutRecordingFeedback(action: .refresh, message: message))
        #expect(signals.messages == [message])
        #expect(slice.value == .default)
        session.cancel()
    }

    @Test("A modifier refusal keeps recording armed")
    func refusalKeepsRecording() {
        let (session, _, signals) = makeSession()
        session.begin(.refresh)
        #expect(session.perform(.refuse("Nope"), for: .refresh))
        #expect(session.recording == .refresh)
        #expect(signals.messages == ["Nope"])
        session.cancel()
    }

    @Test("A refusal stays under its row until another row records")
    func feedbackClearsOnOtherRow() {
        let (session, _, _) = makeSession()
        session.begin(.refresh)
        session.perform(.refuse("Nope"), for: .refresh)
        session.cancel()
        #expect(session.feedback?.action == .refresh)
        session.begin(.refresh)
        #expect(session.feedback?.action == .refresh)
        session.begin(.newTab)
        #expect(session.feedback == nil)
        session.cancel()
    }

    @Test("A chord held by another action asks to reassign, and confirming moves it in one write")
    func conflictAsksToReassign() throws {
        let (session, slice, _) = makeSession()
        session.begin(.executeQuery)
        session.perform(.capture(.character("r", command: true)), for: .executeQuery)
        #expect(session.recording == nil)
        let request = try #require(session.reassignment)
        #expect(request.holders == [.refresh])
        #expect(request.title == String(
            format: String(localized: "Reassign %@ to “%@”?"),
            "⌘R",
            ShortcutAction.executeQuery.displayName
        ))
        #expect(request.message == String(
            format: String(localized: "It is used by “%@” in %@, which will have no shortcut."),
            ShortcutAction.refresh.displayName,
            ShortcutCategory.dataGrid.displayName
        ))
        #expect(slice.value == .default)

        session.confirm(request)
        #expect(session.reassignment == nil)
        #expect(slice.value.boundKey(for: .executeQuery) == .character("r", command: true))
        #expect(slice.value.boundKey(for: .refresh) == nil)
    }

    @Test("Several holders are named together")
    func severalHoldersAreListed() {
        let request = ShortcutReassignment(action: .newTab, key: free, holders: [.formatQuery, .addRow])
        let names = ListFormatter.localizedString(byJoining: [
            String(format: String(localized: "“%@”"), ShortcutAction.formatQuery.displayName),
            String(format: String(localized: "“%@”"), ShortcutAction.addRow.displayName),
        ])
        #expect(request.message == String(format: String(localized: "It is used by %@. They will have no shortcut."), names))
    }

    @Test("Cancelling the reassignment writes nothing")
    func dismissWritesNothing() {
        let (session, slice, _) = makeSession()
        session.begin(.executeQuery)
        session.perform(.capture(.character("r", command: true)), for: .executeQuery)
        session.dismissReassignment()
        #expect(session.reassignment == nil)
        #expect(slice.value == .default)
    }

    @Test("Delete removes the shortcut and ends recording")
    func removeClearsShortcut() {
        let (session, slice, _) = makeSession()
        session.begin(.refresh)
        #expect(session.perform(.remove, for: .refresh))
        #expect(slice.value.boundKey(for: .refresh) == nil)
        #expect(session.recording == nil)
    }

    @Test("Passing events are not consumed")
    func passIsNotConsumed() {
        let (session, _, _) = makeSession()
        session.begin(.refresh)
        #expect(!session.perform(.pass, for: .refresh))
        #expect(session.recording == .refresh)
        #expect(!session.perform(.cancelAndPass, for: .refresh))
        #expect(session.recording == nil)
    }
}

struct ShortcutRecorderLookTests {
    @Test("Idle with a key shows the key")
    func idleWithKey() {
        let look = ShortcutRecorderLook(key: .character("s", command: true), isArmed: false, heldModifiers: [])
        #expect(look.title == "⌘S")
        #expect(!look.isPlaceholder)
        #expect(look.accessibilityValue == "⌘S")
    }

    @Test("Idle with no key or a cleared key shows None as a placeholder")
    func idleWithoutKey() {
        for key in [nil, BoundKey.cleared] {
            let look = ShortcutRecorderLook(key: key, isArmed: false, heldModifiers: [])
            #expect(look.title == String(localized: "None"))
            #expect(look.isPlaceholder)
        }
    }

    @Test("Armed shows the prompt, then the held modifiers in menu order")
    func armedShowsModifiers() {
        let idle = ShortcutRecorderLook(key: .character("s", command: true), isArmed: true, heldModifiers: [])
        #expect(idle.title == String(localized: "Type Shortcut"))
        #expect(idle.accessibilityValue == String(localized: "Recording"))
        #expect(!idle.isPlaceholder)
        let held = ShortcutRecorderLook(key: nil, isArmed: true, heldModifiers: [.command, .shift, .option, .control])
        #expect(held.title == "⌃⌥⇧⌘")
    }
}

@MainActor
struct KeyboardSettingsSummaryTests {
    @Test("The list bar counts customized shortcuts")
    func summaryCountsCustomizations() {
        #expect(KeyboardSettingsView.summary(customized: 0) == String(localized: "No custom shortcuts"))
        #expect(KeyboardSettingsView.summary(customized: 3) == String(format: String(localized: "%lld customized"), 3))
    }
}
