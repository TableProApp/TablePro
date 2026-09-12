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
@Suite("Structure Edit Gate")
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
