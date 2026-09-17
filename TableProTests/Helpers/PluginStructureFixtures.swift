//
//  PluginStructureFixtures.swift
//  TableProTests
//
//  Three values of each structure transfer type, built with the newest initializer and different in
//  every field, for StructureMappingCoverage.
//

import Foundation
import TableProPluginKit

enum PluginStructureFixtures {
    static let columns: [PluginColumnInfo] = [
        column("a", nullable: true, primaryKey: false, generated: false, identity: .always, generation: .stored),
        column("b", nullable: false, primaryKey: true, generated: false, identity: .byDefault, generation: .virtual),
        column("c", nullable: false, primaryKey: false, generated: true, identity: .always, generation: .stored)
    ]

    static let indexes: [PluginIndexInfo] = [
        index("a", unique: true, primary: false, prefix: 1),
        index("b", unique: false, primary: true, prefix: 2),
        index("c", unique: false, primary: false, prefix: 3)
    ]

    static let foreignKeys: [PluginForeignKeyInfo] = ["a", "b", "c"].map(foreignKey)

    static let checkConstraints: [PluginCheckConstraintInfo] = [
        checkConstraint("a", validated: true),
        checkConstraint("b", validated: false),
        checkConstraint("c", validated: true)
    ]

    static let tableMetadata: [PluginTableMetadata] = [
        tableMetadata("a", base: 10),
        tableMetadata("b", base: 20),
        tableMetadata("c", base: 30)
    ]

    private static func column(
        _ suffix: String,
        nullable: Bool,
        primaryKey: Bool,
        generated: Bool,
        identity: IdentityKind,
        generation: GenerationKind
    ) -> PluginColumnInfo {
        PluginColumnInfo(
            name: "name-\(suffix)",
            dataType: "dataType-\(suffix)",
            isNullable: nullable,
            isPrimaryKey: primaryKey,
            defaultValue: "defaultValue-\(suffix)",
            extra: "extra-\(suffix)",
            charset: "charset-\(suffix)",
            collation: "collation-\(suffix)",
            comment: "comment-\(suffix)",
            identityKind: identity,
            isGenerated: generated,
            allowedValues: ["allowedValues-\(suffix)"],
            generationExpression: "generationExpression-\(suffix)",
            generationKind: generation,
            ddlSpelling: "ddlSpelling-\(suffix)",
            ddlDefault: "ddlDefault-\(suffix)",
            ddlGenerationExpression: "ddlGenerationExpression-\(suffix)",
            ddlCollation: "ddlCollation-\(suffix)",
            classificationTypeName: "classificationTypeName-\(suffix)"
        )
    }

    private static func index(_ suffix: String, unique: Bool, primary: Bool, prefix: Int) -> PluginIndexInfo {
        PluginIndexInfo(
            name: "name-\(suffix)",
            columns: ["columns-\(suffix)"],
            isUnique: unique,
            isPrimary: primary,
            type: "type-\(suffix)",
            columnPrefixes: ["columnPrefixes-\(suffix)": prefix],
            whereClause: "whereClause-\(suffix)",
            expressions: ["expressions-\(suffix)"],
            includedColumns: ["includedColumns-\(suffix)"],
            ddlMethodAndKeys: "ddlMethodAndKeys-\(suffix)",
            ddlWhereClause: "ddlWhereClause-\(suffix)"
        )
    }

    private static func foreignKey(_ suffix: String) -> PluginForeignKeyInfo {
        PluginForeignKeyInfo(
            name: "name-\(suffix)",
            column: "column-\(suffix)",
            referencedTable: "referencedTable-\(suffix)",
            referencedColumn: "referencedColumn-\(suffix)",
            referencedDatabase: "referencedDatabase-\(suffix)",
            referencedSchema: "referencedSchema-\(suffix)",
            onDelete: "onDelete-\(suffix)",
            onUpdate: "onUpdate-\(suffix)"
        )
    }

    private static func checkConstraint(_ suffix: String, validated: Bool) -> PluginCheckConstraintInfo {
        PluginCheckConstraintInfo(
            name: "name-\(suffix)",
            expression: "expression-\(suffix)",
            columns: ["columns-\(suffix)"],
            isValidated: validated
        )
    }

    private static func tableMetadata(_ suffix: String, base: Int64) -> PluginTableMetadata {
        PluginTableMetadata(
            tableName: "tableName-\(suffix)",
            dataSize: base + 1,
            indexSize: base + 2,
            totalSize: base + 3,
            avgRowLength: base + 4,
            rowCount: base + 5,
            comment: "comment-\(suffix)",
            engine: "engine-\(suffix)",
            collation: "collation-\(suffix)",
            createTime: Date(timeIntervalSinceReferenceDate: Double(base) * 1_000 + 6),
            updateTime: Date(timeIntervalSinceReferenceDate: Double(base) * 1_000 + 7)
        )
    }
}
