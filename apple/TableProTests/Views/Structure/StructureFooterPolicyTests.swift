//
//  StructureFooterPolicyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// The +/- beneath each section takes its label from the policy and its state and help from the editor, so a view
// that PostgreSQL refuses an added column on dims the pair and says why (#2726).
@MainActor
struct StructureFooterPolicyTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func makeEditor(
        kind: TableInfo.TableType,
        type: DatabaseType = .postgresql,
        isSessionBound: Bool = false
    ) -> StructureDefinitionEditor {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "t",
            columns: [ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true)],
            indexes: [IndexInfo(name: "t_pkey", columns: ["id"], isUnique: true, isPrimary: true, type: "BTREE")],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        let editor = StructureDefinitionEditor(
            manager: manager,
            context: .existingTable(
                connection: TestFixtures.makeConnection(type: type),
                databaseName: "db",
                schemaName: "public",
                tableName: "t",
                objectKind: kind,
                isSessionBound: isSessionBound
            ),
            defaults: suite.defaults
        )
        editor.refresh()
        return editor
    }

    // Selects the section's first row, staging a placeholder where the table has none.
    private func selectFirst(_ section: StructureSection, in editor: StructureDefinitionEditor) {
        if StructureGridEdits.entityIDs(in: section, manager: editor.manager).isEmpty {
            StructureGridEdits.addRow(on: section, manager: editor.manager)
            editor.refresh()
        }
        let id = StructureGridEdits.entityIDs(in: section, manager: editor.manager)[0]
        editor.adapter(for: section).select(entity: id)
    }

    @Test("A table offers both buttons in all four sections")
    func tableOffersEverything() {
        let editor = makeEditor(kind: .table)
        for section in StructureSection.allCases {
            selectFirst(section, in: editor)
            #expect(editor.canAdd(section), "\(section.rawValue)")
            #expect(editor.canRemoveSelection(in: section), "\(section.rawValue)")
            #expect(editor.refusal(adding: section) == nil, "\(section.rawValue)")
        }
    }

    // A save holds what is staged from the press until it ends, so the pair cannot stage more meanwhile.
    @Test("A save in progress dims both buttons in every section and says why")
    func savingDimsThePair() throws {
        let editor = makeEditor(kind: .table)
        selectFirst(.columns, in: editor)
        editor.manager.stageTableComment("Orders")
        _ = try #require(editor.manager.holdForSave())
        editor.refresh()
        #expect(!editor.adapter(for: .columns).model.selection.isEmpty)

        for section in StructureSection.allCases {
            #expect(!editor.canAdd(section), "\(section.rawValue)")
            #expect(!editor.canRemoveSelection(in: section), "\(section.rawValue)")
            #expect(editor.refusal(adding: section) == StructureFooterPolicy.savingReason, "\(section.rawValue)")
        }
    }

    // Dimmed, not hidden: the pair disappearing would read as "this table has no columns".
    @Test("A view keeps the Columns pair, dimmed, with a reason")
    func viewDimsTheColumnsPair() {
        let editor = makeEditor(kind: .view)
        selectFirst(.columns, in: editor)

        #expect(!editor.canAdd(.columns))
        #expect(!editor.canRemoveSelection(in: .columns))
        #expect(!StructureFooterPolicy.labels(for: .columns).add.isEmpty)
        #expect(editor.refusal(adding: .columns)?.isEmpty == false)
    }

    @Test("A materialized view offers an index and refuses a column")
    func materializedViewSplitsBySection() {
        let editor = makeEditor(kind: .materializedView)
        selectFirst(.indexes, in: editor)
        #expect(editor.canAdd(.indexes))
        #expect(editor.canRemoveSelection(in: .indexes))
        #expect(editor.refusal(adding: .indexes) == nil)

        #expect(!editor.canAdd(.columns))
        #expect(editor.refusal(adding: .columns)?.isEmpty == false)
    }

    @Test("A foreign table offers a check constraint and refuses an index")
    func foreignTableSplitsBySection() {
        let editor = makeEditor(kind: .foreignTable)
        #expect(editor.canAdd(.checkConstraints))

        #expect(!editor.canAdd(.indexes))
        #expect(editor.refusal(adding: .indexes)?.isEmpty == false)
    }

    @Test("A foreign table refuses a foreign key, which is the constraint PostgreSQL rejects on one")
    func foreignTableRefusesForeignKeys() {
        let editor = makeEditor(kind: .foreignTable)
        #expect(!editor.canAdd(.foreignKeys))
        #expect(editor.refusal(adding: .foreignKeys)?.isEmpty == false)
    }

    // The pair stays on screen beneath every section; a table whose structure cannot be edited dims it.
    @Test("A table the connection cannot edit offers neither button")
    func uneditableTableDimsThePair() {
        let editor = makeEditor(kind: .table, isSessionBound: true)
        for section in StructureSection.allCases {
            selectFirst(section, in: editor)
            #expect(!editor.canAdd(section), "\(section.rawValue)")
            #expect(!editor.canRemoveSelection(in: section), "\(section.rawValue)")
        }
    }

    @Test("Nothing selected dims Remove without dimming Add and without inventing a reason")
    func emptySelectionOnlyDimsRemove() {
        let editor = makeEditor(kind: .table)
        #expect(editor.canAdd(.columns))
        #expect(!editor.canRemoveSelection(in: .columns))
        #expect(editor.refusal(adding: .columns) == nil)
    }

    @Test("Each section names the add and the drop of its own object")
    func operationsMatchTheirSections() {
        #expect(StructureFooterPolicy.operation(forAdding: .columns) == .addColumn)
        #expect(StructureFooterPolicy.operation(forRemoving: .columns) == .dropColumn)
        #expect(StructureFooterPolicy.operation(forAdding: .indexes) == .addIndex)
        #expect(StructureFooterPolicy.operation(forRemoving: .indexes) == .dropIndex)
        #expect(StructureFooterPolicy.operation(forAdding: .foreignKeys) == .addForeignKey)
        #expect(StructureFooterPolicy.operation(forRemoving: .foreignKeys) == .dropForeignKey)
        #expect(StructureFooterPolicy.operation(forAdding: .checkConstraints) == .addCheckConstraint)
        #expect(StructureFooterPolicy.operation(forRemoving: .checkConstraints) == .dropCheckConstraint)
    }

    @Test("Each section labels both buttons, and no two sections share a label")
    func everySectionHasItsOwnLabels() {
        let labels = StructureSection.allCases.map { StructureFooterPolicy.labels(for: $0) }
        for (section, label) in zip(StructureSection.allCases, labels) {
            #expect(!label.add.isEmpty, "\(section.rawValue)")
            #expect(!label.remove.isEmpty, "\(section.rawValue)")
            #expect(label.add != label.remove, "\(section.rawValue)")
        }
        let adds = Set(labels.map { $0.add })
        let removes = Set(labels.map { $0.remove })
        #expect(adds.count == StructureSection.allCases.count)
        #expect(removes.count == StructureSection.allCases.count)
    }

    // An engine nobody has measured falls back to tables only, so every non-table dims.
    @Test("An uncurated engine dims the pair on a view")
    func uncuratedEngineDimsNonTables() {
        let editor = makeEditor(kind: .view, type: .mysql)
        #expect(!editor.canAdd(.columns))
        #expect(editor.refusal(adding: .columns)?.isEmpty == false)
    }
}
