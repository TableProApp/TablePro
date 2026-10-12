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

    /// The qualifier is the schema the side that read it found the type in, and the two sides do not
    /// have to agree on one: an extension installed in `extensions` on a managed server is the same
    /// type as the one in `public`, and a type in the table's own schema reads bare from there and
    /// qualified from anywhere else. Compared whole, every one of those columns read as changed and
    /// the sync wrote an `ALTER ... TYPE` naming a schema the target does not have.
    @Test("A type compares on the name both sides share, not on the schema each found it in")
    func typesCompareWithoutTheirSchema() throws {
        let source = table(
            [
                column("g", "public.geometry(Point,4326)", classification: "geometry"),
                column("p", "posint", classification: "INTEGER")
            ]
        )
        let target = table(
            [
                column("g", "extensions.geometry(Point,4326)", classification: "geometry"),
                column("p", "public.posint", classification: "INTEGER")
            ]
        )
        let result = try #require(compare(source: source, target: target))
        #expect(result.changes.isEmpty)
    }

    @Test("A different type in another schema is still a change")
    func differentTypesStillCompareAsChanged() throws {
        let source = table([column("p", "public.posint", classification: "INTEGER")])
        let target = table([column("p", "public.negint", classification: "INTEGER")])
        let result = try #require(compare(source: source, target: target))
        #expect(modifiedColumnNames(result) == ["p"])
    }

    /// The type's own spelling is re-said as the declared type rather than dropped: a column read
    /// from the catalog is not a column the structure editor retyped, and a DDL writer reads that
    /// difference to decide whether the column still takes its collation. Only the default and the
    /// generation expression go, because those are SQL text qualified against the source's path.
    /// An index's spellings stay whole: no comparison reads them, and they are the only thing that
    /// keeps an operator class, a sort order and a storage parameter in the index the sync creates.
    @Test("Dropping the catalog spellings keeps the declared type and the index's own spelling")
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
            ddlMethodAndKeys: "USING gin (v public.gin_trgm_ops)",
            ddlWhereClause: "(v IS NOT NULL)"
        )
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
        #expect(first.ddlSpelling == "character varying(10)")
        #expect(first.ddlDefault == nil)
        #expect(first.ddlGenerationExpression == nil)
        #expect(first.dataType == "character varying(10)")
        #expect(first.defaultValue == "'x'::citext")
        #expect(dropped.indexes.first?.ddlMethodAndKeys == "USING gin (v public.gin_trgm_ops)")
        #expect(dropped.indexes.first?.ddlWhereClause == "(v IS NOT NULL)")
        #expect(dropped.indexes.first?.columns == ["lower(v)"])
    }

    /// The spelling a retype clears: `ddlSpelling` answers for the type the column still holds, so a
    /// column the structure editor typed over carries none and a DDL writer stops treating it as a
    /// type the server already accepted this collation on.
    @Test("Retyping a column read from the catalog clears its declared spelling")
    func retypingClearsTheDeclaredSpelling() throws {
        let snapshot = table(
            [
                column(
                    "v", "citext", ddlSpelling: "public.citext",
                    collation: "C", ddlCollation: #"pg_catalog."C""#
                )
            ]
        )
        var dropped = try #require(snapshot.droppingCatalogSpellings(ownSchema: "public").columns.first)
        #expect(dropped.ddlSpelling == "citext")
        dropped.dataType = "integer"
        #expect(dropped.ddlSpelling == nil)
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
