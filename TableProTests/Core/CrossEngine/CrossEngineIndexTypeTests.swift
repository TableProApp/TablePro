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

    @Test("A Redshift DISTKEY and SORTKEY reach PostgreSQL as b-trees, though the two share a family")
    func redshiftKeysBecomeBtrees() {
        let result = CrossEngineStructureTranslator.translate(
            Self.snapshot([Self.index("DISTKEY", type: "DISTKEY"), Self.index("SORTKEY", type: "SORTKEY")]),
            from: .redshift,
            to: .postgresql
        )
        #expect(!result.translated)
        #expect(result.snapshot.indexes.map(\.type) == [.btree, .btree])
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

    /// Redshift and PostgreSQL share a family, so nothing translated the table, and a kept `DISTKEY`
    /// reaches the index writer as `USING distkey`. Measured on PostgreSQL 17.11, that is refused with
    /// `access method "distkey" does not exist`, and the `USING btree` below is created.
    @Test("A Redshift table copied to PostgreSQL writes its keys as b-tree indexes")
    func redshiftCopyWritesBtree() throws {
        let read = TableStructureRead(
            table: PluginTableInfo(name: "events", type: "TABLE", schema: "public", comment: nil),
            columns: [PluginColumnInfo(name: "user_id", dataType: "integer")],
            indexes: [PluginIndexInfo(name: "DISTKEY", columns: ["user_id"], type: "DISTKEY")],
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
        let index = try #require(draft.targetStructure.indexes.first)
        #expect(index.type == .btree)
        #expect(
            PostgreSQLIndexClauses.createStatement(for: index.toPlugin(), qualifiedTable: #""public"."events""#)
                == #"CREATE INDEX "DISTKEY" ON "public"."events" USING btree ("user_id")"#
        )
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
