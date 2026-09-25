//
//  StructureEditGateTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

/// The gate is the one impure half of the decision: it reads the engine's curated matrix and its
/// capability flags, and every call site in the Structure tab asks it rather than reading a flag of
/// its own. They used to read them separately, which is how the footer, the Edit menu's Add Row, the
/// row context menu and the grid's own paste path each got to a different answer. (#2726)
@MainActor
struct StructureEditGateTests {
    private func gate(_ kind: TableInfo.TableType, _ type: DatabaseType = .postgresql) -> StructureEditGate {
        StructureEditGate(databaseType: type, objectKind: kind)
    }

    @Test("A PostgreSQL table takes every edit end to end")
    func tableTakesEverything() {
        let table = gate(.table)
        #expect(table.allowsAnyEdit)
        for operation in StructureEditOperation.allCases {
            #expect(table.allows(operation), "table refused \(operation)")
        }
    }

    @Test("A PostgreSQL view refuses a column and an index but keeps a rename and a default")
    func viewSplitsByOperation() {
        let view = gate(.view)
        #expect(view.allowsAnyEdit)
        #expect(view.allows(.renameColumn))
        #expect(view.allows(.setDefault))
        #expect(view.allows(.commentOnColumn))
        #expect(!view.allows(.addColumn))
        #expect(!view.allows(.setNotNull))
        #expect(!view.allows(.addIndex))
        #expect(!view.allows(.addForeignKey))
        #expect(!view.allows(.reorderColumns))
    }

    @Test("A PostgreSQL materialized view takes an index and refuses a default")
    func materializedViewTakesAnIndex() {
        let matview = gate(.materializedView)
        #expect(matview.allows(.addIndex))
        #expect(matview.allows(.dropIndex))
        #expect(!matview.allows(.setDefault))
        #expect(!matview.allows(.addForeignKey))
    }

    /// PGlite is PostgreSQL 17 running the same driver and the same `CREATE INDEX` and `DROP INDEX`,
    /// and it was left on the tables-only matrix, which refused a matview's index as if the server
    /// did. (#2522)
    @Test("PGlite offers a materialized view the same edits PostgreSQL does")
    func pgliteMatchesPostgreSQL() {
        #expect(PluginManager.shared.structureEditMatrix(for: .pglite) == .postgreSQL)
        let matview = gate(.materializedView, .pglite)
        #expect(matview.allows(.addIndex))
        #expect(matview.allows(.dropIndex))
        #expect(!matview.allows(.setDefault))
    }

    @Test("A materialized view is offered no trigger, while a view and a table keep theirs")
    func triggersFollowTheKind() {
        #expect(!gate(.materializedView).allowsTriggerEditing)
        #expect(!gate(.systemTable).allowsTriggerEditing)
        #expect(gate(.table).allowsTriggerEditing)
        #expect(gate(.view).allowsTriggerEditing)
        #expect(gate(.foreignTable).allowsTriggerEditing)
    }

    /// SQLite, SQL Server and Oracle take an `INSTEAD OF` trigger on a view, and none of them has a
    /// curated edit matrix, so triggers cannot be a cell of it without taking that away.
    @Test("An uncurated engine keeps New Trigger on a view")
    func uncuratedEngineKeepsViewTriggers() {
        #expect(gate(.view, .sqlite).allowsTriggerEditing)
        #expect(!gate(.view, .sqlite).allowsAnyEdit)
    }

    @Test("An engine without trigger editing offers none on any kind")
    func engineWithoutTriggerEditing() {
        #expect(!gate(.table, .clickhouse).allowsTriggerEditing)
    }

    /// Refusing the commit while the editor stayed open dropped whatever was typed, so the lock and
    /// the commit guard come from this one rule.
    @Test("A list whose add the object refuses locks every field, so nothing typed is dropped")
    func refusedAddLocksTheWholeList() {
        #expect(gate(.view).locksField(at: 0, on: .indexes, orderedFields: []))
        #expect(gate(.view).lockedFieldIndices(on: .indexes, orderedFields: [], fieldCount: 5) == Set(0..<5))
        #expect(!gate(.materializedView).locksField(at: 0, on: .indexes, orderedFields: []))
        #expect(gate(.materializedView).locksField(at: 0, on: .foreignKeys, orderedFields: []))
        #expect(gate(.materializedView).locksField(at: 0, on: .checkConstraints, orderedFields: []))
        #expect(!gate(.table).locksField(at: 0, on: .indexes, orderedFields: []))
        #expect(!gate(.table).locksField(at: 0, on: .ddl, orderedFields: []))
    }

    @Test("The Columns list locks field by field")
    func columnsLockPerField() {
        let fields: [StructureColumnField] = [.name, .type, .defaultValue, .comment]
        #expect(gate(.materializedView).lockedFieldIndices(on: .columns, orderedFields: fields, fieldCount: 4) == [1, 2])
        #expect(gate(.table).lockedFieldIndices(on: .columns, orderedFields: fields, fieldCount: 4).isEmpty)
    }

    @Test("A system table allows nothing at all, so the grid has nothing to offer")
    func systemTableAllowsNothing() {
        let system = gate(.systemTable)
        #expect(!system.allowsAnyEdit)
        #expect(system.editableColumnFields.isEmpty)
    }

    @Test("A view keeps exactly Name, Default and Comment unlocked")
    func viewEditableFields() {
        #expect(gate(.view).editableColumnFields == [.name, .defaultValue, .comment])
    }

    /// An engine nobody has curated gets tables only, so a MySQL view's grid is read-only rather than
    /// accepting edits MySQL refuses on a view.
    @Test("An uncurated engine withholds every edit on a view")
    func uncuratedEngineWithholdsOnViews() {
        let view = gate(.view, .mysql)
        #expect(!view.allowsAnyEdit)
        #expect(view.editableColumnFields.isEmpty)
        #expect(!view.allows(.renameColumn))
        #expect(gate(.table, .mysql).allowsAnyEdit)
    }

    /// The gate answers the foreign key arm through `ForeignKeyEditPolicy`, so the engine that has to
    /// recreate the table still offers the edit and the refusal keeps that policy's own wording
    /// rather than the sentence every other constraint shares.
    @Test("An engine that recreates the table to change a key still offers the edit")
    func rebuildEngineOffersForeignKeys() {
        #expect(gate(.table, .sqlite).allows(.addForeignKey))
        #expect(gate(.table, .sqlite).allows(.dropForeignKey))
        #expect(gate(.table).allows(.addForeignKey))
    }

    @Test("A refusing kind reaches the foreign key arm with the kind's own reason")
    func foreignKeyRefusalNamesTheKind() {
        let matview = gate(.materializedView)
        #expect(!matview.allows(.addForeignKey))
        #expect(matview.resolve(.addForeignKey).unavailableReason?.contains("materialized view") == true)
        #expect(matview.foreignKeyAvailability.unavailableReason?.contains("materialized view") == true)
    }

    @Test("A refused operation carries a reason and an accepted one does not")
    func reasonsTravelWithTheRefusal() {
        #expect(gate(.view).kindRefusal(.addIndex)?.isEmpty == false)
        #expect(gate(.view).kindRefusal(.renameColumn) == nil)
        #expect(gate(.materializedView).kindRefusal(.addIndex) == nil)
        #expect(gate(.materializedView).resolve(.setDefault).unavailableReason?.isEmpty == false)
    }

    /// The per-column lock is name-keyed, and the only names it can use are the Columns grid's own
    /// headings. If a provider ever respelled one, the field behind it would silently unlock, so the
    /// two lists are pinned to each other here.
    @Test("The Columns grid's headings are exactly the field display names the lock uses")
    func headingsMatchTheFieldNames() {
        let provider = StructureRowProvider(
            changeManager: StructureChangeManager(),
            tab: .columns,
            databaseType: .postgresql,
            additionalFields: [.primaryKey],
            serverSupport: .unrestricted
        )
        #expect(provider.columns == provider.orderedColumnFields.map(\.displayName))

        let locked = Set(
            StructureColumnField.allCases
                .filter { !gate(.view).editableColumnFields.contains($0) }
                .map(\.displayName)
        )
        let unlocked = provider.columns.filter { !locked.contains($0) }
        #expect(unlocked.contains(StructureColumnField.name.displayName))
        #expect(unlocked.contains(StructureColumnField.defaultValue.displayName))
        #expect(!unlocked.contains(StructureColumnField.type.displayName))
        #expect(!unlocked.contains(StructureColumnField.nullable.displayName))
    }
}
