//
//  CrossEngineIndexTypeTests.swift
//  TableProTests
//
//  Which index type a copied table's index takes on the target, now that a type is whatever the
//  source engine reported rather than one of seven names.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Cross-engine index types")
struct CrossEngineIndexTypeTests {
    private typealias IndexType = EditableIndexDefinition.IndexType

    private static func column(_ name: String) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(), name: name, dataType: "integer", isNullable: true, defaultValue: nil, autoIncrement: false,
            unsigned: false, comment: nil, collation: nil, onUpdate: nil, charset: nil, extra: nil,
            isPrimaryKey: false
        )
    }

    private static func index(
        _ name: String,
        type: String,
        ddlMethodAndKeys: String? = nil
    ) -> EditableIndexDefinition {
        EditableIndexDefinition.from(IndexInfo(
            name: name, columns: ["a"], isUnique: false, isPrimary: false, type: type,
            ddlMethodAndKeys: ddlMethodAndKeys
        ))
    }

    private static func snapshot(_ indexes: [EditableIndexDefinition]) -> TableStructureSnapshot {
        TableStructureSnapshot(name: "items", schema: "public", columns: [column("a")], indexes: indexes)
    }

    @Test("An access method PostgreSQL reported is left out of a MySQL copy, with a note naming it")
    func accessMethodsAreDroppedAcrossFamilies() throws {
        let result = CrossEngineStructureTranslator.translate(
            Self.snapshot([
                Self.index("items_bloom", type: "bloom"),
                Self.index("items_hnsw", type: "hnsw"),
                Self.index("items_spgist", type: "spgist"),
                Self.index("items_btree", type: "btree")
            ]),
            from: .postgresql,
            to: .mysql
        )
        #expect(result.snapshot.indexes.map(\.name) == ["items_btree"])
        let note = try #require(result.notes.first { $0.subject == "items_hnsw" })
        #expect(note.reason == "A HNSW index has no equivalent on this engine.")
        #expect(result.notes.contains { $0.subject == "items_bloom" })
        #expect(result.notes.contains { $0.subject == "items_spgist" })
    }

    @Test("Within PostgreSQL's family an access method and its spelling come across unchanged")
    func accessMethodSurvivesWithinTheFamily() throws {
        let source = Self.snapshot([
            Self.index("items_hnsw", type: "hnsw", ddlMethodAndKeys: "USING hnsw (a vector_l2_ops)")
        ])
        let result = CrossEngineStructureTranslator.translate(source, from: .postgresql, to: .pglite)
        #expect(result.snapshot == source)
        #expect(result.notes.isEmpty)
        let index = try #require(result.snapshot.indexes.first)
        #expect(index.type.rawValue == "HNSW")
        #expect(index.ddlMethodAndKeys == "USING hnsw (a vector_l2_ops)")
    }

    @Test("A Redshift DISTKEY and SORTKEY are left out of a PostgreSQL copy, though the two share a family")
    func redshiftKeysAreLeftOut() {
        let result = CrossEngineStructureTranslator.translate(
            Self.snapshot([Self.index("DISTKEY", type: "DISTKEY"), Self.index("SORTKEY", type: "SORTKEY")]),
            from: .redshift,
            to: .postgresql
        )
        #expect(!result.translated)
        #expect(result.snapshot.indexes.isEmpty)
        #expect(result.notes.map(\.subject) == ["DISTKEY", "SORTKEY"])
        #expect(result.notes.allSatisfy { $0.reason == "On Redshift this is a key of the table, not an index." })
    }

    @Test("Snowflake and BigQuery table keys are left out of a copy to any engine, and the primary key stays")
    func warehouseTableKeysAreLeftOut() {
        let primaryKey = EditableIndexDefinition.from(IndexInfo(
            name: "PRIMARY KEY", columns: ["a"], isUnique: true, isPrimary: true, type: "CONSTRAINT"
        ))
        let snowflake = CrossEngineStructureTranslator.translate(
            Self.snapshot([primaryKey, Self.index("CLUSTERING KEY", type: "CLUSTERING")]),
            from: .snowflake,
            to: .mysql
        )
        #expect(snowflake.snapshot.indexes.map(\.name) == ["PRIMARY KEY"])
        #expect(snowflake.notes.map(\.subject).filter { $0 != "a" } == ["CLUSTERING KEY"])

        let bigQuery = CrossEngineStructureTranslator.translate(
            Self.snapshot([
                Self.index("CLUSTERING", type: "CLUSTERING"),
                Self.index("TIME_PARTITIONING", type: "PARTITION (DAY)")
            ]),
            from: .bigQuery,
            to: .postgresql
        )
        #expect(bigQuery.snapshot.indexes.isEmpty)
        #expect(bigQuery.notes.map(\.subject).filter { $0 != "a" } == ["CLUSTERING", "TIME_PARTITIONING"])
    }

    @Test("A copy from Redshift to Redshift keeps its keys")
    func redshiftToRedshiftKeepsItsKeys() {
        let source = Self.snapshot([Self.index("DISTKEY", type: "DISTKEY")])
        let result = CrossEngineStructureTranslator.translate(source, from: .redshift, to: .redshift)
        #expect(result.snapshot == source)
        #expect(result.notes.isEmpty)
    }

    @Test("A type another engine reports becomes a b-tree, as it did before types were kept")
    func otherEnginesTypesBecomeBtrees() {
        let clustered = CrossEngineStructureTranslator.translate(
            Self.snapshot([Self.index("ix", type: "CLUSTERED")]), from: .mssql, to: .postgresql
        )
        #expect(clustered.snapshot.indexes.map(\.type) == [.btree])
        let art = CrossEngineStructureTranslator.translate(
            Self.snapshot([Self.index("ix", type: "ART")]), from: .duckdb, to: .mysql
        )
        #expect(art.snapshot.indexes.map(\.type) == [.btree])
    }

    @Test("A copy within one database type keeps every reported type and the snapshot itself")
    func sameDatabaseTypeKeepsTheSnapshot() {
        let source = Self.snapshot([Self.index("ix", type: "CLUSTERED"), Self.index("iy", type: "NONCLUSTERED")])
        let result = CrossEngineStructureTranslator.translate(source, from: .mssql, to: .mssql)
        #expect(result.snapshot == source)
        #expect(result.notes.isEmpty)
    }

    @Test("The known types map by family as they always did")
    func knownTypesMapByFamily() {
        let resolve = CrossEngineIndexTranslator.resolvedType
        #expect(resolve(.hash, .postgresql, .sqlite) == .btree)
        #expect(resolve(.hash, .mysql, .postgresql) == .hash)
        #expect(resolve(.fulltext, .mysql, .mariadb) == .fulltext)
        #expect(resolve(.fulltext, .mysql, .postgresql) == nil)
        #expect(resolve(.spgist, .postgresql, .mysql) == nil)
        #expect(resolve(.spgist, .postgresql, .cockroachdb) == .spgist)
    }

    /// Every Redshift table with a distribution key reports it under the name `DISTKEY`, and a
    /// PostgreSQL index name is unique within its schema. Written as a b-tree, measured on
    /// PostgreSQL 17.11, the second table's `CREATE INDEX "DISTKEY"` was refused with
    /// `relation "DISTKEY" already exists`.
    @Test("A Redshift table copied to PostgreSQL creates no index from its keys and names them in the review")
    func redshiftCopyWritesNoKeyIndex() throws {
        let read = TableStructureRead(
            table: PluginTableInfo(name: "events", type: "TABLE", schema: "public", comment: nil),
            columns: [PluginColumnInfo(name: "user_id", dataType: "integer")],
            indexes: [
                PluginIndexInfo(name: "DISTKEY", columns: ["user_id"], type: "DISTKEY"),
                PluginIndexInfo(name: "SORTKEY", columns: ["user_id"], type: "SORTKEY")
            ],
            foreignKeys: [],
            metadata: nil,
            failure: nil
        )
        let snapshot = try #require(read.snapshot)
        let draft = ObjectCopyTableDraft(
            selection: ObjectCopySelection(kind: .table, name: "events", schema: "public"),
            read: read,
            snapshot: snapshot,
            targetSnapshot: nil,
            existsInTarget: false,
            sourceSchema: "public",
            targetSchema: "public",
            targetServerVersion: nil,
            request: ObjectCopyRequest(
                source: Self.endpoint(.redshift),
                destination: .existing(Self.endpoint(.postgresql)),
                objects: [],
                content: .structure,
                existingPolicy: .skip
            )
        )
        #expect(draft.targetStructure.indexes.isEmpty)
        #expect(draft.conversionNotes.map(\.subject) == ["DISTKEY", "SORTKEY"])
    }

    private static func endpoint(_ type: DatabaseType) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: "warehouse", schema: "public"),
            connectionName: type.rawValue,
            databaseType: type,
            safeModeLevel: .silent,
            color: .blue
        )
    }
}
