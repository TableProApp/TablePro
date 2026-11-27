import AppKit
import Darwin
@testable import TableProTextEngine
import Testing

/// The editor reads its whole text on every keystroke and caret move: the run controls, the statement band, the binding
/// writeback and the fold pass. Those reads are cheap only because bridging the storage to a `String` shares the
/// storage's buffer and copies a block only when the next edit touches it. The fold pass and the binding also rely on
/// the bridged value staying as it was while the editor goes on editing.
@MainActor
struct TextStorageReadTests {
    private static let documentUnits = 4_000_000

    @Test()
    func readingTheStringDoesNotCopyTheDocument() {
        let textView = TextView(string: Self.largeDocument())
        textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "-- edited\n")

        let before = Self.bytesInUse()
        let snapshot = textView.string
        textView.replaceCharacters(in: NSRange(location: textView.textStorage.length, length: 0), with: ";")
        let grown = Self.bytesInUse() - before

        // A copy of the document is 8 MB of UTF-16; what sharing costs is one block of it.
        #expect(grown < 2_000_000)
        #expect((snapshot as NSString).length == textView.textStorage.length - 1)
    }

    @Test()
    func theStringIsASnapshotThatLaterEditsLeaveAlone() {
        let textView = TextView(string: "SELECT 1;")
        let snapshot = textView.string

        textView.replaceCharacters(in: NSRange(location: 0, length: 6), with: "DELETE")

        #expect(snapshot == "SELECT 1;")
        #expect(textView.string == "DELETE 1;")
    }

    @Test()
    func theInputSystemReadsTheStorageItself() {
        let textView = TextView(string: Self.largeDocument())

        #expect(textView.attributedString() === textView.textStorage)
    }

    private static func largeDocument() -> String {
        let line = "INSERT INTO t (a, b) VALUES (1, 'héllo'), (2, 'x');\n"
        return String(repeating: line, count: documentUnits / (line as NSString).length)
    }

    private static func bytesInUse() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return statistics.size_in_use
    }
}
