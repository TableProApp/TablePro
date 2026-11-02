import Foundation
@testable import TableProNeo4jCore
import Testing

struct Neo4jValueTextTests {
    private func structure(_ tag: UInt8, _ fields: [PackStreamValue]) -> PackStreamValue {
        .structure(tag: tag, fields: fields)
    }

    @Test("Temporal values read the way Cypher's toString writes them")
    func temporals() {
        #expect(Neo4jValueText.text(structure(0x44, [.int(19_723)])) == "2024-01-01")
        #expect(Neo4jValueText.text(structure(0x44, [.int(-1)])) == "1969-12-31")
        #expect(Neo4jValueText.text(structure(0x74, [.int(45_296_500_000_000)])) == "12:34:56.5")
        #expect(Neo4jValueText.text(structure(0x54, [.int(3_600_000_000_000), .int(25_200)])) == "01:00:00+07:00")
        #expect(Neo4jValueText.text(structure(0x64, [.int(1_704_067_200), .int(0)])) == "2024-01-01T00:00:00")
        #expect(Neo4jValueText.text(structure(0x49, [.int(1_704_067_200), .int(0), .int(25_200)]))
            == "2024-01-01T07:00:00+07:00")
        #expect(Neo4jValueText.text(structure(0x46, [.int(1_704_067_200), .int(0), .int(0)]))
            == "2024-01-01T00:00:00Z")
        #expect(Neo4jValueText.text(structure(0x69, [.int(1_704_067_200), .int(0), .string("Asia/Ho_Chi_Minh")]))
            == "2024-01-01T07:00:00+07:00[Asia/Ho_Chi_Minh]")
    }

    @Test("Durations collapse months into years and seconds into hours and minutes")
    func durations() {
        #expect(Neo4jValueText.text(structure(0x45, [.int(14), .int(3), .int(3_700), .int(500_000_000)]))
            == "P1Y2M3DT1H1M40.5S")
        #expect(Neo4jValueText.text(structure(0x45, [.int(0), .int(0), .int(0), .int(0)])) == "PT0S")
    }

    @Test("Durations too long for Int64 nanoseconds still format")
    func largeDurations() {
        #expect(Neo4jValueText.text(structure(0x45, [.int(0), .int(0), .int(10_000_000_000), .int(0)]))
            == "PT2777777H46M40S")
        #expect(Neo4jValueText.text(structure(0x45, [.int(0), .int(0), .int(-10_000_000_000), .int(0)]))
            == "PT-2777777H-46M-40S")
        #expect(Neo4jValueText.text(structure(0x45, [.int(0), .int(0), .int(-2), .int(500_000_000)])) == "PT-1.5S")
        #expect(Neo4jValueText.text(structure(0x45, [.int(0), .int(0), .int(.max), .int(999_999_999)]))
            == "PT2562047788015215H30M7.999999999S")
        #expect(Neo4jValueText.text(structure(0x45, [.int(0), .int(0), .int(.min), .int(0)]))
            == "PT-2562047788015215H-30M-8S")
    }

    @Test("A path lists its steps in order, with each relationship pointing the way it was walked")
    func pathSteps() throws {
        let first = structure(0x4E, [.int(1), .list([.string("A")]), .map([:]), .string("n1")])
        let second = structure(0x4E, [.int(2), .list([.string("B")]), .map([:]), .string("n2")])
        let knows = structure(0x72, [.int(9), .string("KNOWS"), .map([:]), .string("r9")])
        func steps(_ sequence: [Int64]) throws -> [[String: Any]] {
            let path = structure(0x50, [.list([first, second]), .list([knows]), .list(sequence.map(PackStreamValue.int))])
            let text = try #require(Neo4jValueText.text(path))
            let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let nodes = try #require(object["nodes"] as? [[String: Any]])
            let relationships = try #require(object["relationships"] as? [[String: Any]])
            #expect(nodes.count == relationships.count + 1)
            return relationships
        }

        let forward = try steps([1, 1])
        #expect(forward.map { $0["startElementId"] as? String } == ["n1"])
        #expect(forward.map { $0["endElementId"] as? String } == ["n2"])

        let outAndBack = try steps([1, 1, -1, 0])
        #expect(outAndBack.count == 2)
        #expect(outAndBack.map { $0["elementId"] as? String } == ["r9", "r9"])
        #expect(outAndBack.map { $0["startElementId"] as? String } == ["n1", "n1"])

        let backward = try steps([-1, 1])
        #expect(backward.map { $0["startElementId"] as? String } == ["n2"])
        #expect(backward.map { $0["endElementId"] as? String } == ["n1"])
    }

    @Test("Update counters keep only what changed, and only created or deleted entities count as affected")
    func updateCounts() {
        let setOnly = Neo4jUpdateCounts(summary: ["stats": .map(["properties-set": .int(2)])])
        #expect(setOnly.entitiesChanged == 0)
        #expect(setOnly.counters.map(\.counter) == [.propertiesSet])
        #expect(setOnly.count(.propertiesSet) == 2)

        let created = Neo4jUpdateCounts(summary: ["stats": .map([
            "nodes-created": .int(1_002), "labels-added": .int(1_002), "relationships-created": .int(3),
            "contains-updates": .bool(true)
        ])])
        #expect(created.entitiesChanged == 1_005)
        #expect(created.counters.map(\.counter) == [.nodesCreated, .relationshipsCreated, .labelsAdded])

        #expect(Neo4jUpdateCounts(summary: [:]).counters.isEmpty)
    }

    @Test("Points name their SRID and coordinates")
    func points() {
        #expect(Neo4jValueText.text(structure(0x58, [.int(4_326), .float(1.5), .float(2)]))
            == "point({srid: 4326, x: 1.5, y: 2.0})")
    }

    @Test("A node becomes JSON with its element id, labels and properties")
    func node() throws {
        let node = structure(0x4E, [.int(7), .list([.string("Person")]), .map(["name": .string("Ann")]), .string("4:x:7")])
        let text = try #require(Neo4jValueText.text(node))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["elementId"] as? String == "4:x:7")
        #expect(object["labels"] as? [String] == ["Person"])
        #expect((object["properties"] as? [String: Any])?["name"] as? String == "Ann")
        #expect(Neo4jValueText.typeName(node) == "NODE")
    }

    @Test("A Bolt 4 node falls back to its numeric id")
    func legacyNode() {
        let node = structure(0x4E, [.int(7), .list([]), .map([:])])
        #expect(Neo4jEntity(node)?.elementId == "7")
    }

    @Test("Null stays null and scalars stay plain")
    func scalars() {
        #expect(Neo4jValueText.text(.null) == nil)
        #expect(Neo4jValueText.text(.bool(true)) == "true")
        #expect(Neo4jValueText.text(.float(.infinity)) == "Infinity")
        #expect(Neo4jValueText.text(.list([.int(1), .string("a")])) == #"[1,"a"]"#)
    }
}

struct Neo4jResultTableTests {
    private func node(_ id: String, _ labels: [String], _ properties: [String: PackStreamValue]) -> [PackStreamValue] {
        [.structure(tag: 0x4E, fields: [.int(0), .list(labels.map(PackStreamValue.string)), .map(properties), .string(id)])]
    }

    @Test("Browsing a label spreads nodes into id, labels and one column per property")
    func nodes() {
        let table = Neo4jResultTable.entities(
            kind: .node,
            records: [
                node("a", ["Person"], ["name": .string("Ann"), "age": .int(30)]),
                node("b", ["Person", "Admin"], ["name": .string("Bo"), "email": .string("bo@x")])
            ],
            knownProperties: ["name", "age"]
        )
        #expect(table.columns == ["<id>", "<labels>", "name", "age", "email"])
        #expect(table.typeNames == ["STRING", "LIST", "STRING", "INTEGER", "STRING"])
        #expect(table.rows[0] == ["a", #"["Person"]"#, "Ann", "30", nil])
        #expect(table.rows[1] == ["b", #"["Person","Admin"]"#, "Bo", nil, "bo@x"])
    }

    @Test("Browsing a relationship type shows its start and end nodes")
    func relationships() {
        let relationship = PackStreamValue.structure(tag: 0x52, fields: [
            .int(1), .int(2), .int(3), .string("KNOWS"), .map(["since": .int(2_020)]),
            .string("r1"), .string("n2"), .string("n3")
        ])
        let table = Neo4jResultTable.entities(kind: .relationship, records: [[relationship]], knownProperties: [])
        #expect(table.columns == ["<id>", "<start>", "<end>", "since"])
        #expect(table.rows == [["r1", "n2", "n3", "2020"]])
    }

    @Test("A Cypher result keeps one column per key, typed by its first value")
    func records() {
        let table = Neo4jResultTable.records(keys: ["n", "count"], records: [[.null, .int(2)], [.string("x"), .int(3)]])
        #expect(table.typeNames == ["STRING", "INTEGER"])
        #expect(table.rows == [[nil, "2"], ["x", "3"]])
    }
}
