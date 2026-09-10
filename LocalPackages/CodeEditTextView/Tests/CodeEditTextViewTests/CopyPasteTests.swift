import AppKit
@testable import CodeEditTextView
import Testing

/// Regression tests for issue #2172, "sometimes pasting does not work".
///
/// Two silent failures met here. `copy(_:)` on a bare caret used to clear the pasteboard and
/// write an empty string, so whatever the user had copied elsewhere was gone and every later
/// paste came up empty. `paste(_:)` read `public.utf8-plain-text` alone and returned without a
/// sound for a file-URL-only clipboard, which a plain-text `NSTextView` pastes as the path.
/// Neither view offered `validateUserInterfaceItem`, so AppKit kept the Edit menu items enabled
/// over content they could not touch, and a menu key equivalent is the only route Command+V has
/// to a text view.
@Suite("Copy and paste")
@MainActor
struct CopyPasteTests {
    private static let document = "select * from t where id = 697;\nnext line\n"

    private func makeTextView(_ text: String = document, editable: Bool = true) -> TextView {
        let textView = TextView(string: text)
        textView.isEditable = editable
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.updateFrameIfNeeded()
        textView.frame.size.width = 1_000
        textView.layoutManager.invalidateLayoutForRange(textView.documentRange)
        textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1_000, height: 1_000))
        return textView
    }

    private var numberRange: NSRange {
        (Self.document as NSString).range(of: "697")
    }

    private func seedPasteboard(_ body: (NSPasteboard) -> Void) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        body(pasteboard)
    }

    // MARK: - Pasteboard coercion

    @Test("Plain text resolves unchanged")
    func plainTextResolves() {
        #expect(PasteboardTextReader.plainText(forType: .string, string: "891", data: nil) == "891")
    }

    /// `NSTextView` reads `public.html`, and this reader deliberately does not: the only way to
    /// flatten it is `NSAttributedString`'s HTML importer, measured fetching every remote
    /// subresource the markup references. An HTML-only clipboard must therefore leave Paste
    /// disabled, which tells the user why nothing happened, rather than silently doing nothing.
    @Test("An HTML-only clipboard is not readable, so Paste reports there is nothing to take")
    func htmlIsNotReadable() {
        #expect(PasteboardTextReader.readableTypes.contains(.html) == false)
        seedPasteboard { $0.setString("<b>891</b>", forType: .html) }
        #expect(PasteboardTextReader.hasText() == false)
        #expect(PasteboardTextReader.plainText() == nil)
    }

    @Test("RTF resolves to its text")
    func rtfResolves() {
        let attributed = NSAttributedString(string: "891")
        let data = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])
        #expect(PasteboardTextReader.plainText(forType: .rtf, string: nil, data: data) == "891")
    }

    @Test("A file URL resolves to its path, matching a plain-text NSTextView")
    func fileURLResolvesToPath() {
        let resolved = PasteboardTextReader.plainText(
            forType: .fileURL,
            string: "file:///tmp/example.txt",
            data: nil
        )
        #expect(resolved == "/tmp/example.txt")
    }

    @Test("An empty pasteboard reports no text")
    func emptyPasteboardHasNoText() {
        seedPasteboard { _ in }
        #expect(PasteboardTextReader.hasText() == false)
        #expect(PasteboardTextReader.plainText() == nil)
    }

    // MARK: - Paste

    @Test("Paste replaces the selection with plain-text clipboard contents")
    func pastePlainText() {
        seedPasteboard { $0.setString("891", forType: .string) }
        let textView = makeTextView()
        textView.selectionManager.setSelectedRange(numberRange)
        textView.paste(NSMenuItem())
        #expect(textView.string == "select * from t where id = 891;\nnext line\n")
    }

    @Test("Paste accepts an RTF-only clipboard instead of silently doing nothing")
    func pasteRTFOnly() {
        seedPasteboard { pasteboard in
            let attributed = NSAttributedString(string: "891")
            let range = NSRange(location: 0, length: attributed.length)
            if let data = attributed.rtf(from: range, documentAttributes: [:]) {
                pasteboard.setData(data, forType: .rtf)
            }
        }
        let textView = makeTextView()
        textView.selectionManager.setSelectedRange(numberRange)
        textView.paste(NSMenuItem())
        #expect(textView.string == "select * from t where id = 891;\nnext line\n")
    }

    @Test("Paste accepts a file-URL-only clipboard as the path, like a plain-text NSTextView")
    func pasteFileURLOnly() {
        seedPasteboard { $0.writeObjects([NSURL(fileURLWithPath: "/tmp/example.txt")]) }
        let textView = makeTextView()
        textView.selectionManager.setSelectedRange(numberRange)
        textView.paste(NSMenuItem())
        #expect(textView.string == "select * from t where id = /tmp/example.txt;\nnext line\n")
    }

    @Test("An HTML-only clipboard leaves the document alone and disables Paste")
    func pasteHTMLOnlyIsRefusedAndDisabled() {
        seedPasteboard { $0.setString("<b>891</b>", forType: .html) }
        let textView = makeTextView()
        textView.selectionManager.setSelectedRange(numberRange)
        textView.paste(NSMenuItem())
        #expect(textView.string == Self.document)

        let item = NSMenuItem(title: "", action: #selector(TextView.paste(_:)), keyEquivalent: "")
        #expect(textView.validateUserInterfaceItem(item) == false)
    }

    @Test("Paste normalizes CRLF and lone CR to the document's line ending")
    func pasteNormalizesLineEndings() {
        seedPasteboard { $0.setString("a\r\nb\rc", forType: .string) }
        let textView = makeTextView()
        textView.selectionManager.setSelectedRange(numberRange)
        textView.paste(NSMenuItem())
        #expect(textView.string == "select * from t where id = a\nb\nc;\nnext line\n")
    }

    /// The fast path used to ask `String.contains("\r")`, which compares grapheme clusters, and
    /// `\r\n` is one cluster. A clipboard carrying only CRLF, the common Windows case, therefore
    /// looked like it had no carriage returns at all and kept them.
    @Test("Paste normalizes a CRLF-only clipboard, which has no lone carriage return to find")
    func pasteNormalizesCRLFOnly() {
        #expect("a\r\nb\r\nc".contains("\r") == false)
        seedPasteboard { $0.setString("a\r\nb\r\nc", forType: .string) }
        let textView = makeTextView()
        textView.selectionManager.setSelectedRange(numberRange)
        textView.paste(NSMenuItem())
        #expect(textView.string == "select * from t where id = a\nb\nc;\nnext line\n")
    }

    @Test("Paste leaves the document alone when the clipboard carries nothing readable")
    func pasteWithNothingReadable() {
        seedPasteboard { $0.setString("", forType: NSPasteboard.PasteboardType("public.plain-text")) }
        let textView = makeTextView()
        textView.selectionManager.setSelectedRange(numberRange)
        textView.paste(NSMenuItem())
        #expect(textView.string == Self.document)
    }

    // MARK: - Copy

    @Test("Copy on a bare caret copies the whole line instead of clearing the clipboard")
    func copyCaretCopiesLine() {
        seedPasteboard { $0.setString("EXTERNAL", forType: .string) }
        let textView = makeTextView()
        textView.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))
        textView.copy(NSMenuItem())
        #expect(NSPasteboard.general.string(forType: .string) == "select * from t where id = 697;\n")
    }

    @Test("Copy on a caret in an empty trailing line leaves the clipboard untouched")
    func copyOnEmptyTrailingLineKeepsClipboard() {
        seedPasteboard { $0.setString("EXTERNAL", forType: .string) }
        let textView = makeTextView()
        textView.selectionManager.setSelectedRange(
            NSRange(location: (Self.document as NSString).length, length: 0)
        )
        textView.copy(NSMenuItem())
        #expect(NSPasteboard.general.string(forType: .string) == "EXTERNAL")
    }

    @Test("Copy in an empty document leaves the clipboard untouched")
    func copyInEmptyDocumentKeepsClipboard() {
        seedPasteboard { $0.setString("EXTERNAL", forType: .string) }
        let textView = makeTextView("")
        textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        textView.copy(NSMenuItem())
        #expect(NSPasteboard.general.string(forType: .string) == "EXTERNAL")
    }

    @Test("Copy writes the selection when there is one")
    func copySelection() {
        seedPasteboard { $0.setString("EXTERNAL", forType: .string) }
        let textView = makeTextView()
        textView.selectionManager.setSelectedRange(numberRange)
        textView.copy(NSMenuItem())
        #expect(NSPasteboard.general.string(forType: .string) == "697")
    }

    // MARK: - Menu validation

    private func validation(
        editable: Bool,
        selectionLength: Int,
        clipboardHasText: Bool,
        text: String = document
    ) -> [String: Bool] {
        seedPasteboard { pasteboard in
            if clipboardHasText { pasteboard.setString("X", forType: .string) }
        }
        let textView = makeTextView(text, editable: editable)
        textView.selectionManager.setSelectedRange(NSRange(location: 0, length: selectionLength))
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let selectors: [(String, Selector)] = [
            ("copy", #selector(TextView.copy(_:))),
            ("cut", #selector(TextView.cut(_:))),
            ("paste", #selector(TextView.paste(_:))),
            ("delete", #selector(TextView.delete(_:)))
        ]
        return selectors.reduce(into: [:]) { result, entry in
            item.action = entry.1
            result[entry.0] = textView.validateUserInterfaceItem(item)
        }
    }

    @Test("A read-only view disables Paste, Cut and Delete but still allows Copy")
    func readOnlyValidation() {
        let result = validation(editable: false, selectionLength: 3, clipboardHasText: true)
        #expect(result["paste"] == false)
        #expect(result["cut"] == false)
        #expect(result["delete"] == false)
        #expect(result["copy"] == true)
    }

    @Test("A read-only view with no selection still disables everything but Copy")
    func readOnlyEmptySelectionValidation() {
        let result = validation(editable: false, selectionLength: 0, clipboardHasText: true)
        #expect(result["paste"] == false)
        #expect(result["cut"] == false)
        #expect(result["delete"] == false)
        #expect(result["copy"] == true)
    }

    @Test("An empty clipboard disables Paste")
    func emptyClipboardDisablesPaste() {
        let result = validation(editable: true, selectionLength: 3, clipboardHasText: false)
        #expect(result["paste"] == false)
    }

    @Test("Delete needs a selection, Copy and Cut act on the caret's line")
    func emptySelectionValidation() {
        let result = validation(editable: true, selectionLength: 0, clipboardHasText: true)
        #expect(result["delete"] == false)
        #expect(result["copy"] == true)
        #expect(result["cut"] == true)
    }

    @Test("An empty document disables Copy and Cut but not Paste")
    func emptyDocumentValidation() {
        let result = validation(editable: true, selectionLength: 0, clipboardHasText: true, text: "")
        #expect(result["copy"] == false)
        #expect(result["cut"] == false)
        #expect(result["paste"] == true)
    }
}
