//
//  ResultEditabilityTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct ResultEditabilityTests {
    private func editable(keys: [String]) -> PluginViewRowEditing {
        .editable(TestFixtures.viewTarget(keys: keys))
    }

    private func origin(
        tableName: String? = "users",
        schemaName: String? = nil,
        databaseName: String = "app",
        isEditable: Bool = true,
        isView: Bool = false,
        keysResolved: Bool = true
    ) -> ResultOrigin {
        ResultOrigin(
            tableName: tableName,
            schemaName: schemaName,
            databaseName: databaseName,
            primaryKeyColumns: ["id"],
            isEditable: isEditable,
            isView: isView,
            keysResolved: keysResolved
        )
    }

    @Test("A query result the driver answered for as a view takes the view's gate")
    func queryResultOverAViewTakesTheViewGate() {
        var result = origin()
        result.viewRowEditing = editable(keys: ["id"])
        #expect(ResultEditability.refusal(for: result, currentDatabaseName: "app", currentSchemaName: nil) == nil)
        result.primaryKeyColumns = ["name"]
        #expect(ResultEditability.refusal(for: result, currentDatabaseName: "app", currentSchemaName: nil) == .view(nil))
        result.viewRowEditing = .readOnly(.couldNotCheck)
        #expect(ResultEditability.refusal(for: result, currentDatabaseName: "app", currentSchemaName: nil) == .view(.couldNotCheck))
    }

    @Test("A result that captured its table is editable")
    func capturedTableIsEditable() {
        #expect(ResultEditability.refusal(for: origin(), currentDatabaseName: "app", currentSchemaName: nil) == nil)
    }

    @Test("A result with no captured origin refuses instead of borrowing the tab's table")
    func missingOriginRefuses() {
        #expect(ResultEditability.refusal(for: nil, currentDatabaseName: "app", currentSchemaName: nil) == .unknownTable)
    }

    @Test("A result whose statement resolved no single table refuses")
    func unresolvedTableRefuses() {
        #expect(
            ResultEditability.refusal(for: origin(tableName: nil, isEditable: false), currentDatabaseName: "app", currentSchemaName: nil)
                == .unknownTable
        )
        #expect(
            ResultEditability.refusal(for: origin(tableName: ""), currentDatabaseName: "app", currentSchemaName: nil) == .unknownTable
        )
    }

    @Test("A view refuses, and says so rather than reporting an unknown table")
    func viewRefuses() {
        #expect(ResultEditability.refusal(for: origin(isView: true), currentDatabaseName: "app", currentSchemaName: nil) == .view(nil))
    }

    @Test("An updatable view that exposes its table's key is written like a table")
    func editableViewIsEditable() {
        var view = origin(isView: true)
        view.objectType = .view
        view.viewRowEditing = editable(keys: ["id"])
        #expect(ResultEditability.refusal(for: view, currentDatabaseName: "app", currentSchemaName: nil) == nil)
    }

    @Test("A view refuses when the keys the edit would use are not the driver's")
    func viewWithStaleKeysRefuses() {
        var view = origin(isView: true)
        view.viewRowEditing = editable(keys: ["id"])
        view.primaryKeyColumns = []
        #expect(ResultEditability.refusal(for: view, currentDatabaseName: "app", currentSchemaName: nil) == .view(nil))
        view.primaryKeyColumns = ["code"]
        #expect(ResultEditability.refusal(for: view, currentDatabaseName: "app", currentSchemaName: nil) == .view(nil))
    }

    @Test("A read-only view carries the driver's reason into the refusal")
    func readOnlyViewSaysWhy() {
        var view = origin(isView: true)
        view.viewRowEditing = .readOnly(.keyNotExposed)
        #expect(ResultEditability.refusal(for: view, currentDatabaseName: "app", currentSchemaName: nil) == .view(.keyNotExposed))
    }

    @Test("A materialized view never takes a view's editing answer")
    func materializedViewStaysReadOnly() {
        var matview = origin(isView: true)
        matview.objectType = .materializedView
        matview.viewRowEditing = editable(keys: ["id"])
        #expect(ResultEditability.refusal(for: matview, currentDatabaseName: "app", currentSchemaName: nil) == .view(nil))
    }

    @Test("A result captured against another database refuses once the tab has moved")
    func databaseMoveRefuses() {
        #expect(
            ResultEditability.refusal(for: origin(databaseName: "app"), currentDatabaseName: "reporting", currentSchemaName: nil)
                == .databaseMoved
        )
    }

    @Test("A result read in one schema refuses once the tab's schema picker moved")
    func schemaMoveRefuses() {
        #expect(
            ResultEditability.refusal(
                for: origin(schemaName: "staging"), currentDatabaseName: "app", currentSchemaName: "production"
            ) == .schemaMoved
        )
        #expect(
            ResultEditability.refusal(
                for: origin(schemaName: "staging"), currentDatabaseName: "app", currentSchemaName: "staging"
            ) == nil
        )
    }

    @Test("An unknown database on either side is not treated as a move")
    func unknownDatabaseDoesNotRefuse() {
        #expect(ResultEditability.refusal(for: origin(databaseName: ""), currentDatabaseName: "app", currentSchemaName: nil) == nil)
        #expect(ResultEditability.refusal(for: origin(databaseName: "app"), currentDatabaseName: "", currentSchemaName: nil) == nil)
    }

    @Test("A result whose key columns were never looked up refuses")
    func unresolvedKeysRefuse() {
        #expect(
            ResultEditability.refusal(for: origin(keysResolved: false), currentDatabaseName: "app", currentSchemaName: nil)
                == .keysUnresolved
        )
    }

    @Test("A table that genuinely has no key stays editable, which a whole-row WHERE handles")
    func resolvedButKeylessTableStaysEditable() {
        var keyless = origin()
        keyless.primaryKeyColumns = []
        #expect(ResultEditability.refusal(for: keyless, currentDatabaseName: "app", currentSchemaName: nil) == nil)
    }

    @Test("Every refusal carries a sentence for the user")
    func everyRefusalExplainsItself() {
        let reasons: [PluginViewReadOnlyReason?] = [
            nil, .notUpdatable, .writesRunTriggers, .readsSeveralTables,
            .baseTableHidden, .baseTableHasNoKey, .keyNotExposed, .couldNotCheck,
        ]
        let viewRefusals = reasons.map { ResultEditRefusal.view($0) }
        for refusal in [ResultEditRefusal.unknownTable, .databaseMoved, .schemaMoved, .keysUnresolved] + viewRefusals {
            #expect(!refusal.message.isEmpty)
        }
    }
}
