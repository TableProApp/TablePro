//
//  StructureDeclaredTypeCompareTests.swift
//  TableProTests
//
//  Comparing two schemas now that a PostgreSQL column reports its declared type: the modifiers a
//  comparison has to see, the names two schemas share, and the catalog spellings a script must not
//  carry across.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Declared types in a structure comparison")
struct StructureDeclaredTypeCompareTests {
    private func column(
        _ name: String,
        _ dataType: String,
        classification: String? = nil,
        ddlSpelling: String? = nil,
        defaultValue: String? = nil,
        ddlDefault: String? = nil,
        collation: String? = nil,
        ddlCollation: String? = nil
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: name,
            dataType: dataType,
            isNullable: true,
            defaultValue: defaultValue,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: collation,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: false,
            ddlSpelling: ddlSpelling,
            ddlDefault: ddlDefault,
            ddlGenerationExpression: nil,
            ddlCollation: ddlCollation,
            classificationTypeName: classification
        )
    }

    /// Schemaless on purpose: `fetchTables` on PostgreSQL reports no schema, so the two sides of a
    /// schema-to-schema comparison pair on the table name. A snapshot carrying one would make
    /// `public.t` and `staging.t` two separate objects, and every assertion below vacuous.
    private func table(
        _ columns: [EditableColumnDefinition],
        indexes: [EditableIndexDefinition] = []
    ) -> TableStructureSnapshot {
        TableStructureSnapshot(name: "t", schema: nil, columns: columns, indexes: indexes)
    }

    private func modifiedColumnNames(_ result: TableDiffResult) -> [String] {
        result.changes.compactMap { change in
            guard case .modifyColumn(_, let new) = change else { return nil }
            return new.name
        }
    }

    private func compare(
        source: TableStructureSnapshot,
        target: TableStructureSnapshot
    ) -> TableDiffResult? {
        StructureDiffEngine(options: StructureCompareOptions.default)
            .compare(source: [source], target: [target])
            .results.first
    }

    @Test("A length or a precision difference is a column change")
    func modifiersAreCompared() throws {
        let source = table(
            [column("v", "character varying(10)"), column("n", "numeric(10,2)")]
        )
        let target = table(
            [column("v", "character varying(50)"), column("n", "numeric(12,4)")]
        )
        let result = try #require(compare(source: source, target: target))
        #expect(modifiedColumnNames(result).sorted() == ["n", "v"])
    }

    @Test("Each schema's own enum reads alike, so nothing is reported")
    func ownSchemaTypesMatch() throws {
        let source = table([column("st", "status", classification: "ENUM")])
        let target = table([column("st", "status", classification: "ENUM")])
        let result = try #require(compare(source: source, target: target))
        #expect(result.changes.isEmpty)
    }

    /// PostGIS and citext install into `public`, so the extension type is qualified on both sides,
    /// including the table that lives in `public` itself. Spelled relative there, every
    /// extension-typed column read as changed and the sync wrote an `ALTER ... TYPE geometry` the
    /// target's path cannot resolve.
    @Test("An extension type compares equal between public and another schema")
    func extensionTypesMatchAcrossSchemas() throws {
        let source = table(
            [
                column("g", "public.geometry(Point,4326)", classification: "geometry"),
                column("cit", "public.citext", classification: "citext")
            ]
        )
        let target = table(
            [
                column("g", "public.geometry(Point,4326)", classification: "geometry"),
                column("cit", "public.citext", classification: "citext")
            ]
        )
        let result = try #require(compare(source: source, target: target))
        #expect(result.changes.isEmpty)
    }

    @Test("Dropping the catalog spellings clears the type, default, generation and index spellings")
    func droppingClearsEveryCatalogSpelling() throws {
        let index = EditableIndexDefinition(
            id: UUID(),
            name: "ix",
            columns: ["lower(v)"],
            type: .btree,
            isUnique: false,
            isPrimary: false,
            comment: nil,
            whereClause: "v IS NOT NULL",
            expressions: ["lower(v)"],
            ddlMethodAndKeys: "USING btree (public.lower(v))",
            ddlWhereClause: "(v IS NOT NULL)"
        )
        #expect(index.ddlMethodAndKeys != nil)
        let snapshot = table(
            [
                column(
                    "v", "character varying(10)", classification: nil,
                    ddlSpelling: "public.citext", defaultValue: "'x'::citext", ddlDefault: "'x'::public.citext"
                )
            ],
            indexes: [index]
        )

        let dropped = snapshot.droppingCatalogSpellings(ownSchema: "public")
        let first = try #require(dropped.columns.first)
        #expect(first.ddlSpelling == nil)
        #expect(first.ddlDefault == nil)
        #expect(first.ddlGenerationExpression == nil)
        #expect(first.dataType == "character varying(10)")
        #expect(first.defaultValue == "'x'::citext")
        #expect(dropped.indexes.first?.ddlMethodAndKeys == nil)
        #expect(dropped.indexes.first?.ddlWhereClause == nil)
        #expect(dropped.indexes.first?.columns == ["lower(v)"])
    }

    /// A copy writes the table somewhere else and recreates nothing the types live in, so the
    /// qualified spellings are the only ones that resolve there. Only a comparison drops them.
    @Test("Retargeting a copy keeps the catalog's own spellings")
    func copyKeepsQualifiedSpellings() throws {
        let snapshot = table(
            [column("st", "status", classification: "ENUM", ddlSpelling: "public.status")]
        ).placed(in: "public")
        let moved = ObjectCopyPlanner.retargeted(snapshot, from: "public", to: "staging")
        #expect(moved.columns.first?.ddlSpelling == "public.status")
        #expect(moved.columns.first?.dataType == "status")
    }

    @Test("The classification hint survives dropping the catalog spellings")
    func droppingKeepsTheClassificationHint() throws {
        let snapshot = table(
            [column("st", "status", classification: "ENUM", ddlSpelling: "public.status")]
        )
        let dropped = snapshot.droppingCatalogSpellings(ownSchema: "public")
        #expect(dropped.columns.first?.classificationTypeName == "ENUM")
        #expect(dropped.columns.first?.typeNameForClassification == "ENUM")
    }

    /// A collation is the one spelling a comparison still has to write: dropped outright, a retype
    /// resets the column to its type's default collation. The source schema's own name becomes the
    /// target's, which is the rule the declared type already follows.
    @Test("A collation in the table's own schema is written relative, and every other one stays whole")
    func collationIsSaidRelativeToTheTable() throws {
        let snapshot = table(
            [
                column("a", "text", collation: "Case Insens", ddlCollation: #"public."Case Insens""#),
                column("b", "text", collation: "C", ddlCollation: #"pg_catalog."C""#),
                column("c", "text", collation: "Case Insens", ddlCollation: #"other."Case Insens""#)
            ]
        )
        let dropped = snapshot.droppingCatalogSpellings(ownSchema: "public")
        #expect(dropped.columns[0].ddlCollation == #""Case Insens""#)
        #expect(dropped.columns[1].ddlCollation == #"pg_catalog."C""#)
        #expect(dropped.columns[2].ddlCollation == #"other."Case Insens""#)
    }

    @Test("A schemaless engine keeps every spelling it had")
    func schemalessEngineKeepsQualifiedCollations() throws {
        let snapshot = table(
            [column("a", "varchar(10)", collation: "utf8mb4_general_ci", ddlCollation: "utf8mb4_general_ci")]
        )
        #expect(snapshot.droppingCatalogSpellings(ownSchema: nil).columns.first?.ddlCollation
            == "utf8mb4_general_ci")
    }
}

@Suite("Schema-relative spelling")
struct SchemaRelativeSpellingTests {
    @Test("A name qualified with the table's own schema loses the qualifier")
    func ownSchemaQualifierGoes() {
        #expect(SchemaRelativeSpelling.of("public.ci", ownSchema: "public") == "ci")
        #expect(SchemaRelativeSpelling.of(#"public."Case Insens""#, ownSchema: "public") == #""Case Insens""#)
        #expect(SchemaRelativeSpelling.of(#""My Schema"."C""#, ownSchema: "My Schema") == #""C""#)
        #expect(SchemaRelativeSpelling.of(#""a""b".c"#, ownSchema: #"a"b"#) == "c")
    }

    @Test("Any other name is left exactly as the catalog wrote it")
    func everyOtherNameIsKept() {
        #expect(SchemaRelativeSpelling.of(#"pg_catalog."C""#, ownSchema: "public") == #"pg_catalog."C""#)
        #expect(SchemaRelativeSpelling.of("other.ci", ownSchema: "public") == "other.ci")
        #expect(SchemaRelativeSpelling.of("ci", ownSchema: "public") == "ci")
        #expect(SchemaRelativeSpelling.of("public.ci", ownSchema: nil) == "public.ci")
        #expect(SchemaRelativeSpelling.of("public.ci", ownSchema: "") == "public.ci")
        #expect(SchemaRelativeSpelling.of("Public.ci", ownSchema: "public") == "Public.ci")
    }
}
