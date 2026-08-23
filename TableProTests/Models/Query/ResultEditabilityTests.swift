//
//  ResultEditabilityTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("ResultEditability")
struct ResultEditabilityTests {
    private func origin(
        tableName: String? = "users",
        databaseName: String = "app",
        isEditable: Bool = true,
        isView: Bool = false,
        keysResolved: Bool = true
    ) -> ResultOrigin {
        ResultOrigin(
            tableName: tableName,
            schemaName: nil,
            databaseName: databaseName,
            primaryKeyColumns: ["id"],
            isEditable: isEditable,
            isView: isView,
            keysResolved: keysResolved
        )
    }

    @Test("A result that captured its table is editable")
    func capturedTableIsEditable() {
        #expect(ResultEditability.refusal(for: origin(), currentDatabaseName: "app") == nil)
    }

    @Test("A result with no captured origin refuses instead of borrowing the tab's table")
    func missingOriginRefuses() {
        #expect(ResultEditability.refusal(for: nil, currentDatabaseName: "app") == .unknownTable)
    }

    @Test("A result whose statement resolved no single table refuses")
    func unresolvedTableRefuses() {
        #expect(
            ResultEditability.refusal(for: origin(tableName: nil, isEditable: false), currentDatabaseName: "app")
                == .unknownTable
        )
        #expect(
            ResultEditability.refusal(for: origin(tableName: ""), currentDatabaseName: "app") == .unknownTable
        )
    }

    @Test("A view refuses, and says so rather than reporting an unknown table")
    func viewRefuses() {
        #expect(ResultEditability.refusal(for: origin(isView: true), currentDatabaseName: "app") == .view)
    }

    @Test("A result captured against another database refuses once the tab has moved")
    func databaseMoveRefuses() {
        #expect(
            ResultEditability.refusal(for: origin(databaseName: "app"), currentDatabaseName: "reporting")
                == .databaseMoved
        )
    }

    @Test("An unknown database on either side is not treated as a move")
    func unknownDatabaseDoesNotRefuse() {
        #expect(ResultEditability.refusal(for: origin(databaseName: ""), currentDatabaseName: "app") == nil)
        #expect(ResultEditability.refusal(for: origin(databaseName: "app"), currentDatabaseName: "") == nil)
    }

    @Test("A result whose key columns were never looked up refuses")
    func unresolvedKeysRefuse() {
        #expect(
            ResultEditability.refusal(for: origin(keysResolved: false), currentDatabaseName: "app")
                == .keysUnresolved
        )
    }

    @Test("A table that genuinely has no key stays editable, which a whole-row WHERE handles")
    func resolvedButKeylessTableStaysEditable() {
        var keyless = origin()
        keyless.primaryKeyColumns = []
        #expect(ResultEditability.refusal(for: keyless, currentDatabaseName: "app") == nil)
    }

    @Test("Every refusal carries a sentence for the user")
    func everyRefusalExplainsItself() {
        for refusal in [ResultEditRefusal.unknownTable, .view, .databaseMoved, .keysUnresolved] {
            #expect(!refusal.message.isEmpty)
        }
    }
}
