//
//  IndexTypeTests.swift
//  TableProTests
//
//  The index type as an open vocabulary: what the engine reports is what the app keeps, on the wire
//  and across a paste.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Index type")
struct IndexTypeTests {
    private typealias IndexType = EditableIndexDefinition.IndexType

    private static func index(_ type: IndexType) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: "ix", columns: ["a"], type: type, isUnique: false, isPrimary: false, comment: nil
        )
    }

    @Test("A type is compared by its uppercased name, so a catalog's lowercase spelling is a known type")
    func rawValueIsUppercased() {
        #expect(IndexType(rawValue: "spgist") == .spgist)
        #expect(IndexType(rawValue: "btree") == .btree)
        #expect(IndexType(rawValue: "hnsw").rawValue == "HNSW")
    }

    @Test("SP-GiST is offered with the other known types")
    func knownTypesIncludeSpGist() {
        #expect(IndexType.knownTypes == [.btree, .hash, .fulltext, .spatial, .gin, .gist, .brin, .spgist])
    }

    @Test("A type outside the known list is encoded as its name alone, the JSON the closed list wrote")
    func wireFormatIsTheBareName() throws {
        let data = try JSONEncoder().encode(Self.index(IndexType(rawValue: "bloom")))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "BLOOM")
    }

    @Test("An index copied by an older build decodes with its type, and an unknown type survives")
    func decodesEveryTypeName() throws {
        for (wire, expected) in [("GIN", IndexType.gin), ("hnsw", IndexType(rawValue: "HNSW"))] {
            let json = """
                {"id":"\(UUID().uuidString)","name":"ix","columns":["a"],"type":"\(wire)",
                "isUnique":false,"isPrimary":false,"columnPrefixes":{}}
                """
            let decoded = try JSONDecoder().decode(EditableIndexDefinition.self, from: Data(json.utf8))
            #expect(decoded.type == expected)
        }
    }
}

@Suite("Index type paste")
struct IndexTypePasteTests {
    private static func index(_ type: String) -> EditableIndexDefinition {
        EditableIndexDefinition.from(IndexInfo(name: "ix", columns: ["a"], isUnique: false, isPrimary: false, type: type))
    }

    @Test("A Redshift DISTKEY pasted into PostgreSQL is a b-tree, never USING distkey")
    func redshiftKeyBecomesBtree() {
        #expect(Self.index("DISTKEY").pasted(from: .redshift, into: .postgresql).type == .btree)
        #expect(Self.index("SORTKEY").pasted(from: .redshift, into: .postgresql).type == .btree)
    }

    @Test("A PostgreSQL access method keeps its name within the family and is a b-tree elsewhere")
    func accessMethodFollowsTheTarget() {
        #expect(Self.index("hnsw").pasted(from: .postgresql, into: .pglite).type.rawValue == "HNSW")
        #expect(Self.index("hnsw").pasted(from: .postgresql, into: .mysql).type == .btree)
        #expect(Self.index("gin").pasted(from: .postgresql, into: .mysql).type == .btree)
    }

    @Test("Within one database type the reported type is kept")
    func sameTypeKeepsItsType() {
        #expect(Self.index("CLUSTERED").pasted(from: .mssql, into: .mssql).type.rawValue == "CLUSTERED")
        #expect(Self.index("bloom").pasted(from: .postgresql, into: .postgresql).type.rawValue == "BLOOM")
    }

    @Test("A copy whose source is not recorded keeps its type, since only the known types were ever written")
    func unrecordedSourceKeepsItsType() {
        #expect(Self.index("GIN").pasted(from: nil, into: .mysql).type == .gin)
    }
}
