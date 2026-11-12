//
//  ObjectCopyRowCutTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class CappedSourceDriver: PluginDriverStub, @unchecked Sendable {
    let declaredLimit: Int?
    let rowCount: Int

    init(declaredLimit: Int?, rowCount: Int) {
        self.declaredLimit = declaredLimit
        self.rowCount = rowCount
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        var header = PluginStreamHeader(columns: ["id", "name"], columnTypeNames: [])
        header.rowLimit = declaredLimit
        let rows: [PluginRow] = (0 ..< rowCount).map { [.text(String($0)), .text("row\($0)")] }
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(header))
            continuation.yield(.rows(rows))
            continuation.finish()
        }
    }
}

private final class WritingTargetDriver: PluginDriverStub, @unchecked Sendable {
    var parameterStyle: ParameterStyle { .questionMark }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ name: String) -> String { "`\(name)`" }
}

struct ObjectCopyRowCutTests {
    private func step() -> ObjectCopyTableStep {
        ObjectCopyTableStep(
            selection: ObjectCopySelection(kind: .table, name: "orders", schema: "public"),
            dropStatements: [],
            sequenceStatements: [],
            createStatements: [],
            truncateStatements: [],
            columns: ["id", "name"],
            targetColumnTypeNames: [:],
            primaryKeyColumns: ["id"],
            sourceQuery: "SELECT `id`, `name` FROM `public`.`orders`",
            targetTable: "orders",
            targetSchema: "public",
            estimatedRows: nil,
            copiesData: true,
            copiesIdentityColumn: false,
            coercer: nil,
            serverSideInsert: nil,
            note: nil
        )
    }

    private func copy(from source: CappedSourceDriver) async throws -> ObjectCopyRowCopier.Outcome {
        try await ObjectCopyRowCopier(step: step(), sourceDatabaseType: .mysql, targetDatabaseType: .mysql)
            .copy(from: source, to: WritingTargetDriver()) { _ in }
    }

    // A 6,000,000-row SAP HANA table arrived as 5,000,000 rows and the copy reported success.
    @Test("A copy whose source stream stopped at the driver's limit says where")
    func cutStreamIsReported() async throws {
        let outcome = try await copy(from: CappedSourceDriver(declaredLimit: 3, rowCount: 3))

        #expect(outcome.inserted == 3)
        #expect(outcome.rowCut == 3)
    }

    @Test("A copy that read fewer rows than the driver's limit is whole")
    func shortStreamIsWhole() async throws {
        let outcome = try await copy(from: CappedSourceDriver(declaredLimit: 10, rowCount: 3))

        #expect(outcome.inserted == 3)
        #expect(outcome.rowCut == nil)
    }

    @Test("A cut table's outcome carries the export's wording")
    func cutOutcomeCarriesTheWarning() {
        let selection = ObjectCopySelection(kind: .table, name: "orders", schema: "public")
        let result = ObjectCopyRunResult(
            outcomes: [
                ObjectCopyObjectOutcome(
                    selection: selection,
                    rowsCopied: 3,
                    error: nil,
                    warning: StreamRowCutWarning.text(table: selection.qualifiedName, limit: 3)
                )
            ],
            rowsCopied: 3,
            cancelled: false,
            createdDatabase: nil
        )

        #expect(result.warnings == [StreamRowCutWarning.text(table: selection.qualifiedName, limit: 3)])
        #expect(result.failedCount == 0)
    }
}
