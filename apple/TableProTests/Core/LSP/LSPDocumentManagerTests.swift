import Foundation
@testable import TablePro
import Testing

@MainActor
struct LSPDocumentManagerTests {
    @Test("a version starts at zero on open, rises by one per change and starts over on a reopen")
    func versionsFollowOpenAndChange() {
        let manager = LSPDocumentManager()
        let uri = "file:///query-1.sql"
        let edit = [LSPTextDocumentContentChangeEvent(text: "SELECT 1")]

        #expect(manager.changeDocument(uri: uri, changes: edit)?.textDocument.version == nil)
        #expect(manager.openDocument(uri: uri, languageId: "sql", text: "").version == 0)
        #expect(manager.changeDocument(uri: uri, changes: edit)?.textDocument.version == 1)
        #expect(manager.changeDocument(uri: uri, changes: edit)?.textDocument.version == 2)

        _ = manager.openDocument(uri: uri, languageId: "sql", text: "")
        #expect(manager.version(for: uri) == 0)
        #expect(manager.closeDocument(uri: uri)?.uri == uri)
        #expect(manager.version(for: uri) == nil)
        #expect(manager.closeDocument(uri: uri)?.uri == nil)
    }

    @Test("a full text change encodes no range, and a range change round-trips with it")
    func changeEventEncodesItsRangeOnlyWhenSet() throws {
        let full = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(LSPTextDocumentContentChangeEvent(text: "x"))
        ) as? [String: Any]
        #expect(full?.keys.sorted() == ["text"])

        let ranged = LSPTextDocumentContentChangeEvent(
            range: LSPRange(start: LSPPosition(line: 3, character: 1), end: LSPPosition(line: 4, character: 0)),
            text: "y"
        )
        let data = try JSONEncoder().encode(ranged)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?.keys.sorted() == ["range", "text"])
        #expect(try JSONDecoder().decode(LSPTextDocumentContentChangeEvent.self, from: data) == ranged)
    }
}
