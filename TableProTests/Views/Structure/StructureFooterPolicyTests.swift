//
//  StructureFooterPolicyTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

/// The "+" and "-" under a structure list used to take their label, their enabled state and their
/// tooltip from three different switches, and only the Foreign Keys one asked about the object at
/// all. So a view offered an enabled "Add Column" over a statement PostgreSQL always refuses, with
/// nothing to explain it. (#2726)
@Suite("Structure Footer Policy")
struct StructureFooterPolicyTests {
    private func resolve(
        tab: StructureTab,
        kind: TableInfo.TableType,
        matrix: StructureObjectEditMatrix = .postgreSQL,
        canEditSchema: Bool = true,
        hasSelection: Bool = true
    ) -> StructureFooterCapability {
        StructureFooterPolicy.resolve(
            tab: tab,
            canEditSchema: canEditSchema,
            hasSelection: hasSelection,
            resolve: { operation in
                StructureEditEligibility.resolve(
                    operation,
                    on: kind,
                    matrix: matrix,
                    engineAllows: true,
                    engineName: "PostgreSQL",
                    canEditSchema: canEditSchema
                )
            }
        )
    }

    @Test("A table offers both buttons on all four editable tabs")
    func tableOffersEverything() {
        for tab in [StructureTab.columns, .indexes, .foreignKeys, .checkConstraints] {
            let capability = resolve(tab: tab, kind: .table)
            #expect(capability.canAdd, "\(tab.rawValue)")
            #expect(capability.canRemove, "\(tab.rawValue)")
            #expect(capability.unavailableReason == nil, "\(tab.rawValue)")
        }
    }

    /// Shown and dimmed, not hidden. The pair disappearing would read as "this tab has no columns",
    /// and the tooltip is the only place the refusal can be stated.
    @Test("A view keeps the Columns pair on screen, dimmed, with a reason")
    func viewDimsTheColumnsPair() {
        let capability = resolve(tab: .columns, kind: .view)
        #expect(!capability.canAdd)
        #expect(!capability.canRemove)
        #expect(capability.isActive)
        #expect(capability.addLabel.isEmpty == false)
        #expect(capability.unavailableReason?.isEmpty == false)
    }

    @Test("A materialized view offers an index and refuses a column")
    func materializedViewSplitsByTab() {
        let indexes = resolve(tab: .indexes, kind: .materializedView)
        #expect(indexes.canAdd)
        #expect(indexes.canRemove)
        #expect(indexes.unavailableReason == nil)

        let columns = resolve(tab: .columns, kind: .materializedView)
        #expect(!columns.canAdd)
        #expect(columns.unavailableReason?.isEmpty == false)
    }

    @Test("A foreign table offers a check constraint and refuses an index")
    func foreignTableSplitsByTab() {
        let checks = resolve(tab: .checkConstraints, kind: .foreignTable)
        #expect(checks.canAdd)

        let indexes = resolve(tab: .indexes, kind: .foreignTable)
        #expect(!indexes.canAdd)
        #expect(indexes.unavailableReason?.isEmpty == false)
    }

    @Test("A foreign table refuses a foreign key, which is the constraint PostgreSQL rejects on one")
    func foreignTableRefusesForeignKeys() {
        let keys = resolve(tab: .foreignKeys, kind: .foreignTable)
        #expect(!keys.canAdd)
        #expect(keys.unavailableReason?.isEmpty == false)
    }

    /// Today's behaviour, preserved on purpose: an engine that cannot edit structure at all hides the
    /// pair rather than showing two dead buttons on every tab.
    @Test("An engine that cannot edit structure hides the pair entirely")
    func readOnlyEngineHidesThePair() {
        let capability = resolve(tab: .columns, kind: .table, canEditSchema: false)
        #expect(!capability.isActive)
        #expect(capability.addLabel.isEmpty)
        #expect(!capability.canAdd)
        #expect(!capability.canRemove)
    }

    @Test("Nothing selected dims Remove without dimming Add and without inventing a reason")
    func emptySelectionOnlyDimsRemove() {
        let capability = resolve(tab: .columns, kind: .table, hasSelection: false)
        #expect(capability.canAdd)
        #expect(!capability.canRemove)
        #expect(capability.unavailableReason == nil)
    }

    @Test("The tabs with nothing to add have no operation and no pair")
    func nonEditableTabsHaveNoPair() {
        for tab in [StructureTab.ddl, .parts, .triggers] {
            #expect(StructureFooterPolicy.operation(forAdding: tab) == nil, "\(tab.rawValue)")
            #expect(StructureFooterPolicy.operation(forRemoving: tab) == nil, "\(tab.rawValue)")
            #expect(!resolve(tab: tab, kind: .table).isActive, "\(tab.rawValue)")
        }
    }

    @Test("Each editable tab names the add and the drop of its own object")
    func operationsMatchTheirTabs() {
        #expect(StructureFooterPolicy.operation(forAdding: .columns) == .addColumn)
        #expect(StructureFooterPolicy.operation(forRemoving: .columns) == .dropColumn)
        #expect(StructureFooterPolicy.operation(forAdding: .indexes) == .addIndex)
        #expect(StructureFooterPolicy.operation(forRemoving: .indexes) == .dropIndex)
        #expect(StructureFooterPolicy.operation(forAdding: .foreignKeys) == .addForeignKey)
        #expect(StructureFooterPolicy.operation(forRemoving: .foreignKeys) == .dropForeignKey)
        #expect(StructureFooterPolicy.operation(forAdding: .checkConstraints) == .addCheckConstraint)
        #expect(StructureFooterPolicy.operation(forRemoving: .checkConstraints) == .dropCheckConstraint)
    }

    /// An engine nobody has measured falls back to tables only, so every non-table dims rather than
    /// offering an edit its server may refuse.
    @Test("An uncurated engine dims the pair on a view")
    func uncuratedEngineDimsNonTables() {
        let capability = resolve(tab: .columns, kind: .view, matrix: .tablesOnly)
        #expect(!capability.canAdd)
        #expect(capability.isActive)
        #expect(capability.unavailableReason?.isEmpty == false)
    }
}
