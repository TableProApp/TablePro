//
//  SchemaWriteGateDenialTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

// A denial came back as a failed statement, so Create Database, the schema editor and Create Table
// showed the user's own Cancel at the gate as an error.
@MainActor
struct SchemaWriteGateDenialTests {
    private let scope = DatabaseScope(connectionId: UUID(), database: "app", schema: nil)

    private func gateFailure(of body: () async throws -> Void) async -> GatedOperationFailure? {
        do {
            try await body()
            return nil
        } catch {
            return GatedOperationFailure(error)
        }
    }

    private func runCreateDatabase(gate: any ExecutionGate) async -> GatedOperationFailure? {
        await gateFailure {
            try await DatabaseManager.shared.runContainerOperation(
                description: "Create database \"sales\"",
                kind: .schemaMutation,
                scope: scope,
                databaseType: .postgresql,
                event: nil,
                gate: gate
            ) { _ in
                Issue.record("The driver was asked after the gate said no")
            }
        }
    }

    @Test("A Cancel at the gate ends a database operation quietly, before the driver is asked")
    func containerOperationCancelIsQuiet() async {
        let failure = await runCreateDatabase(gate: AlwaysDenyGate.cancelling)

        #expect(failure == .cancelledByUser)
        #expect(failure?.message == nil)
    }

    @Test("A refused database operation says why and is not a failed statement")
    func containerOperationRefusalExplainsItself() async {
        let failure = await runCreateDatabase(gate: AlwaysDenyGate(reason: "Safe Mode is read-only"))

        #expect(failure == .refused("Safe Mode is read-only"))
        #expect(failure?.reportsFailure == false)
    }

    @Test("A Cancel at the gate ends a schema editor apply quietly")
    func containerStatementsCancelIsQuiet() async {
        let failure = await gateFailure {
            try await DatabaseManager.shared.runContainerStatements(
                .statements([SchemaStatement(sql: "CREATE SCHEMA sales", description: "Create", isDestructive: false)]),
                description: "Create Schema",
                scope: scope,
                databaseType: .postgresql,
                event: nil,
                gate: AlwaysDenyGate.cancelling
            )
        }

        #expect(failure == .cancelledByUser)
    }

    @Test("A Cancel at the gate ends a Create Table quietly")
    func createTableCancelIsQuiet() async {
        let failure = await gateFailure {
            try await DatabaseManager.shared.executeCreateTable(
                statements: ["CREATE TABLE invoices (id INT)"],
                databaseType: .postgresql,
                scope: scope,
                gate: AlwaysDenyGate.cancelling
            )
        }

        #expect(failure == .cancelledByUser)
        #expect(failure?.message == nil)
    }
}
