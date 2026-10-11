//
//  ImportOutcomeMessageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import Testing

struct ImportOutcomeMessageTests {
    @Test("Connections and saved queries are counted in one message")
    func countsConnectionsAndQueries() {
        let message = ImportOutcomeMessage(ImportOutcome(connectionsAdded: 1, savedQueriesAdded: 2))

        #expect(message.title == String(localized: "Import Complete"))
        #expect(message.message == "\(String(localized: "1 connection was imported.")) \(Self.queriesAdded(2))")
    }

    @Test("Replaced connections count as imported")
    func replacedConnectionsCount() {
        let message = ImportOutcomeMessage(ImportOutcome(connectionsAdded: 2, connectionsReplaced: 1))

        #expect(message.title == String(localized: "Import Complete"))
        #expect(message.message == String(format: String(localized: "%d connections were imported."), 3))
    }

    @Test("Queries added to existing connections report without a connection sentence")
    func queriesOnly() {
        let message = ImportOutcomeMessage(ImportOutcome(savedQueriesAdded: 1, savedQueriesNotImported: 3))

        #expect(message.title == String(localized: "Import Complete"))
        #expect(message.message == "\(String(localized: "1 saved query was added.")) \(Self.queriesNotImported(3))")
    }

    @Test("Nothing written reads as nothing imported, not as a failure")
    func nothingImported() {
        let message = ImportOutcomeMessage(ImportOutcome())

        #expect(message.title == String(localized: "Nothing Imported"))
        #expect(message.message == String(localized: "Everything selected was already in your library."))
    }

    @Test("Saved queries skipped with nothing else written are counted, not called already saved")
    func nothingImportedCountsSkippedQueries() {
        let message = ImportOutcomeMessage(ImportOutcome(savedQueriesNotImported: 2))

        #expect(message.title == String(localized: "Nothing Imported"))
        #expect(message.message == String(format: String(localized: "%d saved queries were not imported."), 2))
    }

    @Test("A query store failure after connections were saved is incomplete")
    func savedQueriesFailedAfterConnections() {
        let message = ImportOutcomeMessage(ImportOutcome(connectionsAdded: 1, failure: .savedQueriesNotSaved))

        #expect(message.title == String(localized: "Import Incomplete"))
        #expect(message.message == "\(String(localized: "1 connection was imported.")) \(String(localized: "The saved queries could not be saved."))")
    }

    @Test("A query store failure with no connection saved is a failure")
    func savedQueriesFailedAlone() {
        let message = ImportOutcomeMessage(ImportOutcome(failure: .savedQueriesNotSaved))

        #expect(message.title == String(localized: "Import Failed"))
        #expect(message.message == String(localized: "The saved queries could not be saved."))
    }

    @Test("A library or connection failure reports the failure only", arguments: [
        ImportFailure.libraryUnreadable,
        ImportFailure.connectionsNotSaved,
    ])
    func storeFailures(failure: ImportFailure) {
        let message = ImportOutcomeMessage(ImportOutcome(failure: failure))

        #expect(message.title == String(localized: "Import Failed"))
        let expected = failure == .libraryUnreadable
            ? String(localized: "TablePro could not read your connection library, so nothing was imported.")
            : String(localized: "The connections could not be saved.")
        #expect(message.message == expected)
    }

    private static func queriesAdded(_ count: Int) -> String {
        String(format: String(localized: "%d saved queries were added."), count)
    }

    private static func queriesNotImported(_ count: Int) -> String {
        String(format: String(localized: "%d saved queries were not imported."), count)
    }
}
