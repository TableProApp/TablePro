import AppKit
@testable import TablePro
import Testing

@MainActor
struct ConnectionTagTokenFieldTests {
    private final class Recorder {
        var reports: [[String]] = []
    }

    private func makeField(
        committed: [String] = [],
        recorder: Recorder
    ) -> (window: NSWindow, field: NSTokenField, coordinator: ConnectionTagTokenField.Coordinator) {
        let representable = ConnectionTagTokenField(
            tokens: committed,
            completions: ["production", "staging"],
            onChange: { recorder.reports.append($0) }
        )
        let coordinator = representable.makeCoordinator()
        let field = NSTokenField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.delegate = coordinator
        field.objectValue = committed.map(TagToken.init(name:))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(field)
        return (window, field, coordinator)
    }

    @Test("Typing a name without committing it creates nothing")
    func typingAloneCommitsNothing() throws {
        let recorder = Recorder()
        let (window, field, coordinator) = makeField(recorder: recorder)
        defer { window.orderOut(nil) }
        // The field holds its delegate weakly.
        try withExtendedLifetime(coordinator) {
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)

            editor.insertText("s", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.insertText("t", replacementRange: NSRange(location: NSNotFound, length: 0))

            #expect(recorder.reports.isEmpty)
            #expect(coordinator.committed.isEmpty)
        }
    }

    @Test("Return turns the typed name into one committed tag")
    func returnCommitsTheName() throws {
        let recorder = Recorder()
        let (window, field, coordinator) = makeField(recorder: recorder)
        defer { window.orderOut(nil) }
        try withExtendedLifetime(coordinator) {
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)

            editor.insertText("Analytics", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.insertNewline(nil)

            #expect(recorder.reports == [["analytics"]])
        }
    }

    @Test("Ending editing commits a name still being typed, as a Save click does")
    func endingEditingCommitsPendingText() throws {
        let recorder = Recorder()
        let (window, field, coordinator) = makeField(committed: ["production"], recorder: recorder)
        defer { window.orderOut(nil) }
        try withExtendedLifetime(coordinator) {
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.moveToEndOfDocument(nil)
            editor.insertText("billing", replacementRange: NSRange(location: NSNotFound, length: 0))

            #expect(window.makeFirstResponder(nil))

            #expect(recorder.reports.last == ["production", "billing"])
        }
    }

    @Test("Deleting a committed token reports the shorter list")
    func deletionCommits() {
        let recorder = Recorder()
        let (window, field, coordinator) = makeField(committed: ["production", "staging"], recorder: recorder)
        defer { window.orderOut(nil) }

        field.objectValue = [TagToken(name: "staging")]
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

        #expect(recorder.reports == [["staging"]])
    }

    @Test("Only a list that lost tokens and gained none is a deletion")
    func removalRule() {
        #expect(ConnectionTagTokens.isRemoval(["a"], from: ["a", "b"]))
        #expect(!ConnectionTagTokens.isRemoval(["a", "b", "c"], from: ["a", "b"]))
        #expect(!ConnectionTagTokens.isRemoval(["a", "pro"], from: ["a", "b", "c"]))
        #expect(!ConnectionTagTokens.isRemoval(["a", "b"], from: ["a", "b"]))
        #expect(ConnectionTagTokens.isRemoval(["a"], from: ["a", "a"]))
    }
}
