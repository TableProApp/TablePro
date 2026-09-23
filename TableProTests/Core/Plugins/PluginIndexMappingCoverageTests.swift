//
//  PluginIndexMappingCoverageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Plugin index mapping coverage")
struct PluginIndexMappingCoverageTests {
    @Test("Index fixtures built with the published initializer are caught")
    func fixturesFromThePublishedInitializerAreCaught() {
        let older = PluginStructureFixtures.indexes.map {
            PluginIndexInfo(
                name: $0.name, columns: $0.columns, isUnique: $0.isUnique, isPrimary: $0.isPrimary, type: $0.type,
                columnPrefixes: $0.columnPrefixes, whereClause: $0.whereClause
            )
        }
        let problems = StructureMappingCoverage.fixtureProblems(older)
        #expect(problems.contains("Every PluginIndexInfo fixture leaves expressions at nil"))
        #expect(problems.contains("Every PluginIndexInfo fixture leaves ddlMethodAndKeys at nil"))
    }

    @Test("A mapper that leaves the index spellings behind is caught")
    func droppedIndexSpellingIsCaught() {
        let fixtures = PluginStructureFixtures.indexes
        let mapped = fixtures.map {
            IndexInfo(
                name: $0.name, columns: $0.columns, isUnique: $0.isUnique, isPrimary: $0.isPrimary, type: $0.type,
                columnPrefixes: $0.columnPrefixes, whereClause: $0.whereClause, expressions: $0.expressions,
                includedColumns: $0.includedColumns
            )
        }
        let problems = StructureMappingCoverage.carryProblems(from: fixtures, to: mapped, appOnly: ["id"])
        #expect(problems.contains { $0.hasPrefix("ddlMethodAndKeys:") })
        #expect(problems.contains { $0.hasPrefix("ddlWhereClause:") })
    }

    @Test("A mapper that reads every index as valid is caught")
    func droppedValidityIsCaught() {
        let fixtures = PluginStructureFixtures.indexes
        let mapped = fixtures.map {
            IndexInfo(
                name: $0.name, columns: $0.columns, isUnique: $0.isUnique, isPrimary: $0.isPrimary, type: $0.type,
                columnPrefixes: $0.columnPrefixes, whereClause: $0.whereClause, expressions: $0.expressions,
                includedColumns: $0.includedColumns, ddlMethodAndKeys: $0.ddlMethodAndKeys,
                ddlWhereClause: $0.ddlWhereClause
            )
        }
        let problems = StructureMappingCoverage.carryProblems(from: fixtures, to: mapped, appOnly: ["id"])
        #expect(problems == ["isValid: PluginIndexInfo has false, IndexInfo has true"])
    }
}
