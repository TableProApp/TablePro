//
//  JSONElementBatches.swift
//  JSONImportPlugin
//

import Foundation
import TableProPluginKit

// The values of a `.json` file that become rows. A value `JSONSerialization` cannot read throws in
// every error mode, as it failed the whole-file parse the import used to run.
protocol JSONElementSequence {
    mutating func next() throws -> Any?
    func close()
}

// The elements of one array of a UTF-8 file, each read and parsed as it is reached.
struct JSONStreamedElements: JSONElementSequence {
    private var reader: JSONDocumentReader
    private var hasMore: Bool

    init(reader: JSONDocumentReader, arrayAt offset: Int) throws {
        self.reader = reader
        try self.reader.seek(to: offset)
        hasMore = try self.reader.enterArray()
    }

    var heldByteCount: Int { reader.heldByteCount }

    mutating func next() throws -> Any? {
        guard hasMore else { return nil }
        let value = try reader.readValue()
        hasMore = try reader.continueArray()
        let object: Any = try autoreleasepool { try JSONSerialization.jsonObject(with: value, options: .fragmentsAllowed) }
        return object
    }

    func close() {
        reader.close()
    }
}

// The elements of a file `JSONSerialization` has already read whole.
struct JSONParsedElements: JSONElementSequence {
    private let elements: [Any]
    private var cursor = 0

    init(_ elements: [Any]) {
        self.elements = elements
    }

    mutating func next() -> Any? {
        guard cursor < elements.count else { return nil }
        defer { cursor += 1 }
        return elements[cursor]
    }

    func close() {}
}

// Hands a `.json` file's rows to `RowImportRunner` a batch at a time, numbered by their place in the
// array, and keeps the elements that are not objects, which Skip and Continue passes over.
struct JSONElementBatches {
    private var elements: any JSONElementSequence
    private let elementsPerBatch: Int
    private let skipsUnreadableElements: Bool
    private let maxRecordedErrors: Int

    private(set) var elementsRead = 0
    private(set) var unreadableElements: [PluginImportResult.ImportStatementError] = []

    // Every unreadable element, counted past the end of the capped `unreadableElements` list.
    private(set) var unreadableElementCount = 0

    init(
        elements: any JSONElementSequence,
        elementsPerBatch: Int,
        skipsUnreadableElements: Bool,
        maxRecordedErrors: Int
    ) {
        self.elements = elements
        self.elementsPerBatch = max(1, elementsPerBatch)
        self.skipsUnreadableElements = skipsUnreadableElements
        self.maxRecordedErrors = maxRecordedErrors
    }

    mutating func next() throws -> [RowImportRunner.Entry]? {
        var batch: [RowImportRunner.Entry] = []
        var elementsInBatch = 0
        while elementsInBatch < elementsPerBatch, let element = try elements.next() {
            elementsInBatch += 1
            elementsRead += 1
            let number = elementsRead
            do {
                let row = try autoreleasepool { try JSONImportParsing.row(from: element) }
                guard !row.isEmpty else { continue }
                batch.append((number, row))
            } catch {
                guard skipsUnreadableElements else { throw error }
                recordUnreadableElement(number, error: error)
            }
        }
        return elementsInBatch == 0 ? nil : batch
    }

    func close() {
        elements.close()
    }

    private mutating func recordUnreadableElement(_ number: Int, error: any Error) {
        unreadableElementCount += 1
        guard unreadableElements.count < maxRecordedErrors else { return }
        unreadableElements.append(.init(
            statement: "row \(number)",
            line: number,
            errorMessage: error.localizedDescription
        ))
    }
}
