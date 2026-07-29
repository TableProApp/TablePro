import Foundation
@testable import TableProMobile
import Testing
import UIKit
import UniformTypeIdentifiers

@Suite("ClipboardExporter pasteboard payload")
struct ClipboardExporterPasteboardTests {
    @Test("payload carries the text as utf8 plain text")
    func carriesText() {
        let payload = ClipboardExporter.pasteboardPayload("secret-value")
        let first = payload.items.first
        #expect(first?[UTType.utf8PlainText.identifier] as? String == "secret-value")
    }

    @Test("payload is local only so it never syncs via Universal Clipboard")
    func localOnly() {
        let payload = ClipboardExporter.pasteboardPayload("x")
        #expect(payload.options[.localOnly] as? Bool == true)
    }

    @Test("payload expires about a minute after copy")
    func expires() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let payload = ClipboardExporter.pasteboardPayload("x", now: now)
        let expiry = payload.options[.expirationDate] as? Date
        #expect(expiry == now.addingTimeInterval(ClipboardExporter.pasteboardExpiry))
    }
}
