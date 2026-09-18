//
//  PluginStructureMappingTests.swift
//  TableProTests
//
//  The one crossing from each structure transfer type to the app's model carries every field, and a
//  field PluginKit gains fails here until the fixtures, the model and the crossing all carry it.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Plugin structure mapping")
struct PluginStructureMappingTests {
    private static let columns = PluginStructureFixtures.columns

    private func expectCovered<Source, Target>(
        _ fixtures: [Source],
        appOnly: Set<String> = ["id"],
        sourceLocation: SourceLocation = #_sourceLocation,
        map: (Source) -> Target
    ) {
        let fixtureProblems = StructureMappingCoverage.fixtureProblems(fixtures)
        #expect(fixtureProblems.isEmpty, "\(fixtureProblems.joined(separator: "\n"))", sourceLocation: sourceLocation)

        let carryProblems = StructureMappingCoverage.carryProblems(
            from: fixtures, to: fixtures.map(map), appOnly: appOnly
        )
        #expect(carryProblems.isEmpty, "\(carryProblems.joined(separator: "\n"))", sourceLocation: sourceLocation)
    }

    @Test("A column carries every field of the plugin's column")
    func columnCarriesEveryField() {
        expectCovered(Self.columns) { ColumnInfo($0) }
    }

    @Test("An index carries every field of the plugin's index")
    func indexCarriesEveryField() {
        expectCovered(PluginStructureFixtures.indexes) { IndexInfo($0) }
    }

    @Test("A foreign key carries every field of the plugin's foreign key")
    func foreignKeyCarriesEveryField() {
        expectCovered(PluginStructureFixtures.foreignKeys) { ForeignKeyInfo($0) }
    }

    @Test("A check constraint carries every field of the plugin's check constraint")
    func checkConstraintCarriesEveryField() {
        expectCovered(PluginStructureFixtures.checkConstraints) { CheckConstraintInfo($0) }
    }

    @Test("Table metadata carries every field of the plugin's table metadata")
    func tableMetadataCarriesEveryField() {
        expectCovered(PluginStructureFixtures.tableMetadata, appOnly: []) { TableMetadata($0) }
    }

    @Test("A mapper that leaves a field behind is caught")
    func droppedFieldIsCaught() {
        let mapped = Self.columns.map {
            ColumnInfo(
                name: $0.name, dataType: $0.dataType, isNullable: $0.isNullable, isPrimaryKey: $0.isPrimaryKey,
                defaultValue: $0.defaultValue, extra: $0.extra, charset: $0.charset, collation: $0.collation,
                comment: $0.comment, isGenerated: $0.isGenerated, allowedValues: $0.allowedValues,
                generationExpression: $0.generationExpression, generationKind: $0.generationKind,
                ddlSpelling: $0.ddlSpelling, ddlDefault: $0.ddlDefault,
                ddlGenerationExpression: $0.ddlGenerationExpression, ddlCollation: $0.ddlCollation,
                classificationTypeName: $0.classificationTypeName
            )
        }
        let problems = StructureMappingCoverage.carryProblems(from: Self.columns, to: mapped, appOnly: ["id"])
        #expect(problems.contains { $0.hasPrefix("identityKind:") })
    }

    @Test("A mapper that swaps two Bool fields is caught")
    func swappedBoolFieldsAreCaught() {
        let mapped = Self.columns.map {
            ColumnInfo(
                name: $0.name, dataType: $0.dataType, isNullable: $0.isGenerated, isPrimaryKey: $0.isPrimaryKey,
                defaultValue: $0.defaultValue, extra: $0.extra, charset: $0.charset, collation: $0.collation,
                comment: $0.comment, identityKind: $0.identityKind, isGenerated: $0.isNullable,
                allowedValues: $0.allowedValues, generationExpression: $0.generationExpression,
                generationKind: $0.generationKind, ddlSpelling: $0.ddlSpelling, ddlDefault: $0.ddlDefault,
                ddlGenerationExpression: $0.ddlGenerationExpression, ddlCollation: $0.ddlCollation,
                classificationTypeName: $0.classificationTypeName
            )
        }
        let problems = StructureMappingCoverage.carryProblems(from: Self.columns, to: mapped, appOnly: ["id"])
        #expect(problems.contains { $0.hasPrefix("isNullable:") })
        #expect(problems.contains { $0.hasPrefix("isGenerated:") })
    }

    @Test("A mapper that swaps two String fields is caught")
    func swappedStringFieldsAreCaught() {
        let mapped = Self.columns.map {
            ColumnInfo(
                name: $0.name, dataType: $0.dataType, isNullable: $0.isNullable, isPrimaryKey: $0.isPrimaryKey,
                defaultValue: $0.defaultValue, extra: $0.extra, charset: $0.collation, collation: $0.charset,
                comment: $0.comment, identityKind: $0.identityKind, isGenerated: $0.isGenerated,
                allowedValues: $0.allowedValues, generationExpression: $0.generationExpression,
                generationKind: $0.generationKind, ddlSpelling: $0.ddlSpelling, ddlDefault: $0.ddlDefault,
                ddlGenerationExpression: $0.ddlGenerationExpression, ddlCollation: $0.ddlCollation,
                classificationTypeName: $0.classificationTypeName
            )
        }
        let problems = StructureMappingCoverage.carryProblems(from: Self.columns, to: mapped, appOnly: ["id"])
        #expect(problems.contains { $0.hasPrefix("charset:") })
        #expect(problems.contains { $0.hasPrefix("collation:") })
    }

    @Test("Fixtures built with an initializer that predates a field are caught")
    func fixturesFromAnOlderInitializerAreCaught() {
        let older = Self.columns.map {
            PluginColumnInfo(
                name: $0.name, dataType: $0.dataType, isNullable: $0.isNullable, isPrimaryKey: $0.isPrimaryKey,
                defaultValue: $0.defaultValue, extra: $0.extra, charset: $0.charset, collation: $0.collation,
                comment: $0.comment, identityKind: $0.identityKind, isGenerated: $0.isGenerated,
                allowedValues: $0.allowedValues, generationExpression: $0.generationExpression,
                generationKind: $0.generationKind
            )
        }
        let problems = StructureMappingCoverage.fixtureProblems(older)
        #expect(problems.contains("Every PluginColumnInfo fixture leaves ddlSpelling at nil"))
    }

    @Test("Fixtures that give two Bool fields one pattern are caught")
    func boolFieldsSharingAPatternAreCaught() {
        let shared = Self.columns.map {
            PluginColumnInfo(
                name: $0.name, dataType: $0.dataType, isNullable: $0.isNullable, isPrimaryKey: $0.isPrimaryKey,
                defaultValue: $0.defaultValue, extra: $0.extra, charset: $0.charset, collation: $0.collation,
                comment: $0.comment, identityKind: $0.identityKind, isGenerated: $0.isNullable,
                allowedValues: $0.allowedValues, generationExpression: $0.generationExpression,
                generationKind: $0.generationKind, ddlSpelling: $0.ddlSpelling, ddlDefault: $0.ddlDefault,
                ddlGenerationExpression: $0.ddlGenerationExpression, ddlCollation: $0.ddlCollation,
                classificationTypeName: $0.classificationTypeName
            )
        }
        let problems = StructureMappingCoverage.fixtureProblems(shared)
        #expect(problems.contains { $0.hasPrefix("PluginColumnInfo fixtures give isGenerated, isNullable the same pattern") })
    }

    @Test("Two fixtures are refused")
    func twoFixturesAreRefused() {
        let problems = StructureMappingCoverage.fixtureProblems(Array(Self.columns.prefix(2)))
        #expect(problems == ["PluginColumnInfo needs at least three fixtures, got 2"])
    }
}
