//
//  ImportStatementFormatTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

/// The statement dialog runs a file of statements. A format that needs a target table is routed to
/// the row mapping sheet instead, so listing one in the statement dialog's picker only ever
/// produced "No target table configured for row import" once the user pressed Import.
@Suite("Import statement format availability")
struct ImportStatementFormatTests {
    private func isStatementFormat(
        requiresTargetTable: Bool = false,
        supported: [String] = [],
        excluded: [String] = [],
        databaseTypeId: String = "MySQL"
    ) -> Bool {
        ImportRouting.isStatementFormat(
            requiresTargetTable: requiresTargetTable,
            supportedDatabaseTypeIds: supported,
            excludedDatabaseTypeIds: excluded,
            databaseTypeId: databaseTypeId
        )
    }

    @Test("A format needing a target table is never offered")
    func targetTableFormatIsRejected() {
        #expect(isStatementFormat(requiresTargetTable: true) == false)
    }

    @Test("A format needing a target table is rejected even where it supports the database")
    func targetTableFormatIsRejectedDespiteSupport() {
        #expect(isStatementFormat(requiresTargetTable: true, supported: ["MySQL"]) == false)
    }

    @Test("A statement format with no restrictions is offered")
    func unrestrictedStatementFormatIsOffered() {
        #expect(isStatementFormat())
    }

    @Test("An empty supported list means every database")
    func emptySupportedListMeansEveryDatabase() {
        #expect(isStatementFormat(supported: [], databaseTypeId: "Trino"))
    }

    @Test("A supported list that omits the database rejects it")
    func unsupportedDatabaseIsRejected() {
        #expect(isStatementFormat(supported: ["PostgreSQL"], databaseTypeId: "MySQL") == false)
    }

    @Test("An excluded database is rejected")
    func excludedDatabaseIsRejected() {
        #expect(isStatementFormat(excluded: ["MySQL"], databaseTypeId: "MySQL") == false)
    }

    @Test("Routing sends the two kinds to different sheets")
    func routingMatchesTheAvailabilityRule() {
        #expect(ImportRouting.route(formatId: "sql", requiresTargetTable: false) == .statement(formatId: "sql"))
        #expect(ImportRouting.route(formatId: "csv", requiresTargetTable: true) == .rowMapping(formatId: "csv"))
    }
}
