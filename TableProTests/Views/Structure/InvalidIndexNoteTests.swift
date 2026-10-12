//
//  InvalidIndexNoteTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct InvalidIndexNoteTests {
    private static func index(_ name: String, valid: Bool = true) -> IndexInfo {
        IndexInfo(name: name, columns: ["code"], isUnique: false, isPrimary: false, type: "BTREE", isValid: valid)
    }

    @Test("No note when every index is valid")
    func noNoteWhenAllValid() {
        #expect(InvalidIndexNote(indexes: [Self.index("orders_pkey"), Self.index("orders_code_idx")]) == nil)
        #expect(InvalidIndexNote(indexes: []) == nil)
    }

    @Test("The note names the invalid index and none of the valid ones")
    func namesOnlyTheInvalidIndex() throws {
        let note = try #require(InvalidIndexNote(indexes: [
            Self.index("orders_code_idx"),
            Self.index("orders_code_key", valid: false)
        ]))
        #expect(note.text.contains("orders_code_key"))
        #expect(!note.text.contains("orders_code_idx"))
        #expect(note.text.contains("orders_code_key is invalid"))
        #expect(note.text.contains("REINDEX"))
        #expect(note.systemImage == "exclamationmark.triangle")
    }

    @Test("Several invalid indexes are listed in one note")
    func listsEveryInvalidIndex() throws {
        let note = try #require(InvalidIndexNote(indexes: [
            Self.index("orders_email_key", valid: false),
            Self.index("orders_pkey"),
            Self.index("orders_code_idx_ccnew", valid: false)
        ]))
        #expect(note.text.contains("orders_email_key"))
        #expect(note.text.contains("orders_code_idx_ccnew are invalid"))
        #expect(!note.text.contains("orders_pkey"))
    }
}
