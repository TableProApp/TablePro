//
//  StructureGeneratedColumnFieldTests.swift
//  TableProTests
//
//  StructureColumnField is non-frozen, so every switch over it ends in `@unknown default`.
//  A new case therefore compiles clean and silently does nothing, which no build failure
//  would ever reveal. These tests are the only thing standing in for the compiler here.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor @Suite("Generated column structure fields")
struct StructureGeneratedColumnFieldTests {
    private func column() -> EditableColumnDefinition {
        var column = EditableColumnDefinition.placeholder()
        column.name = "total"
        column.dataType = "int"
        return column
    }

    @Test("every declared field appears in the canonical order, or the grid drops it silently")
    func canonicalOrderCoversEveryField() {
        let ordered = StructureRowProvider.orderedFields(
            for: .mysql,
            additionalFields: Set(StructureColumnField.allCases)
        )
        let missing = StructureColumnField.allCases.filter { !ordered.contains($0) }
        #expect(missing.isEmpty, "Fields absent from canonicalFieldOrder are discarded: \(missing)")
    }

    @Test("editing the Generated cell sets the kind")
    func editingGeneratedCellSetsKind() {
        var target = column()
        StructureEditingSupport.updateColumn(
            &target, at: 0, with: GenerationKind.stored.rawValue, orderedFields: [.generated]
        )
        #expect(target.generationKind == .stored)
    }

    @Test("editing the Expression cell sets the expression")
    func editingExpressionCellSetsExpression() {
        var target = column()
        StructureEditingSupport.updateColumn(
            &target, at: 0, with: "qty * price", orderedFields: [.generationExpression]
        )
        #expect(target.generationExpression == "qty * price")
    }

    @Test("clearing Generated drops the expression, so no orphan expression is staged")
    func clearingGeneratedDropsExpression() {
        var target = column()
        target.generationKind = .stored
        target.generationExpression = "qty * price"
        StructureEditingSupport.updateColumn(
            &target, at: 0, with: StructureRowProvider.notGeneratedOption, orderedFields: [.generated]
        )
        #expect(target.generationKind == nil)
        #expect(target.generationExpression == nil)
    }

    @Test("a changed generation field tints its cell as modified")
    func changedGenerationFieldsAreReportedModified() {
        let old = column()
        var new = old
        new.generationKind = .virtual
        new.generationExpression = "qty * price"

        let indices = StructureEditingSupport.columnModifiedIndices(
            old: old, new: new, orderedFields: [.generated, .generationExpression]
        )
        #expect(indices == [0, 1])
    }

    @Test("the Generated cell offers a three-state choice, not a boolean")
    func generatedCellIsThreeState() {
        #expect(StructureRowProvider.generationOptions.count == 3)
        #expect(StructureRowProvider.generationOptions.contains(GenerationKind.stored.rawValue))
        #expect(StructureRowProvider.generationOptions.contains(GenerationKind.virtual.rawValue))
    }

    @Test("engines without generated columns never offer the fields")
    func fieldsAreEngineScoped() {
        let fields = PluginManager.shared.structureColumnFields(for: .clickhouse)
        #expect(!fields.contains(.generated))
        #expect(!fields.contains(.generationExpression))
    }

    @Test("a copied column keeps its generation detail")
    func copyKeepsGenerationDetail() {
        var source = column()
        source.generationKind = .stored
        source.generationExpression = "qty * price"

        let copy = source.withNewIdentity()
        #expect(copy.id != source.id)
        #expect(copy.generationKind == .stored)
        #expect(copy.generationExpression == "qty * price")
    }

    @Test("the plugin bridge carries generation detail, so DDL is never generated without it")
    func pluginBridgeCarriesGenerationDetail() {
        var source = column()
        source.generationKind = .virtual
        source.generationExpression = "qty * price"

        let plugin = source.toPlugin()
        #expect(plugin.generationExpression == "qty * price")
        #expect(plugin.generationKind == .virtual)
        #expect(plugin.isGenerated)
    }
}
