//
//  ImportFieldListTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ImportFieldListTests {
    private func request(
        table: String? = "people",
        signature: String = CSVImportOptions().detectionSignature,
        attempt: Int = 0
    ) -> ImportFieldDetectionRequest {
        ImportFieldDetectionRequest(targetTable: table, detectionSignature: signature, attempt: attempt)
    }

    private func list(readFor request: ImportFieldDetectionRequest) -> ImportFieldList<String> {
        var list = ImportFieldList<String>()
        list.finishRead(["id;name;email"], for: request)
        return list
    }

    /// A semicolon CSV read with a comma delimiter has one field, `id;name;email`. Picking `;`
    /// changes only the detection options, and the sheet used to keep the one field because the
    /// table it was matched against had not changed.
    @Test("A new delimiter reads the file again for the same table")
    func delimiterChangeNeedsARead() {
        var options = CSVImportOptions()
        options.delimiter = .comma
        let fields = list(readFor: request(signature: options.detectionSignature))
        options.delimiter = .semicolon
        #expect(fields.needsRead(for: request(signature: options.detectionSignature)))
    }

    @Test("A new delimiter reads the file again for a new table")
    func delimiterChangeNeedsAReadWithoutATable() {
        var options = CSVImportOptions()
        options.delimiter = .comma
        let fields = list(readFor: request(table: nil, signature: options.detectionSignature))
        options.delimiter = .semicolon
        #expect(fields.needsRead(for: request(table: nil, signature: options.detectionSignature)))
    }

    /// Switching destination and back asks for the same request again, and a second read would
    /// replace the user's edits with fresh matches.
    @Test("The request a list was read for needs no second read")
    func sameRequestKeepsTheList() {
        let fields = list(readFor: request())
        #expect(!fields.needsRead(for: request()))
        #expect(fields.rows == ["id;name;email"])
    }

    @Test("Another table reads the file again")
    func otherTableNeedsARead() {
        #expect(list(readFor: request(table: "people")).needsRead(for: request(table: "orders")))
    }

    @Test("Try Again reads the file again")
    func retryNeedsARead() {
        #expect(list(readFor: request(attempt: 0)).needsRead(for: request(attempt: 1)))
    }

    @Test("A list that was never read needs a read")
    func unreadListNeedsARead() {
        #expect(ImportFieldList<String>().needsRead(for: request()))
    }

    /// Picking another table empties the list before its read. Going back to the first table
    /// before that read ends has to read again, not find its request answered by an empty list.
    @Test("A discarded list answers no request, the one it was read for included")
    func discardForgetsTheRequest() {
        var fields = list(readFor: request(table: "people"))
        fields.discard()
        #expect(fields.rows.isEmpty)
        #expect(fields.needsRead(for: request(table: "people")))
    }
}
