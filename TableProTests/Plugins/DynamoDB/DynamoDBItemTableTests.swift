import Foundation
import TableProPluginKit
import Testing

struct DynamoDBItemTableTests {
    struct ClassificationCase: Sendable, CustomTestStringConvertible {
        let value: DynamoDBAttributeValue
        let displayName: String
        let classification: String
        var testDescription: String { displayName }
    }

    private static func schema() throws -> DynamoDBTableSchema {
        try DynamoDBTableSchema(describeTableResponse: DynamoDBJSON.parse(#"""
        {
          "Table": {
            "TableName": "Orders",
            "KeySchema": [
              {"AttributeName": "pk", "KeyType": "HASH"},
              {"AttributeName": "sk", "KeyType": "RANGE"}
            ],
            "AttributeDefinitions": [
              {"AttributeName": "pk", "AttributeType": "S"},
              {"AttributeName": "sk", "AttributeType": "N"},
              {"AttributeName": "status", "AttributeType": "S"}
            ],
            "GlobalSecondaryIndexes": [
              {
                "IndexName": "byStatus",
                "KeySchema": [{"AttributeName": "status", "KeyType": "HASH"}],
                "Projection": {"ProjectionType": "ALL"}
              }
            ]
          }
        }
        """#))
    }

    private static func item(_ values: [String: DynamoDBAttributeValue]) -> DynamoDBItem {
        values
    }

    private static func ids(_ items: [DynamoDBItem]) -> [String] {
        items.map { item in
            guard case .string(let id)? = item["id"] else { return "?" }
            return id
        }
    }

    @Test("Columns run preferred first, then table keys, then the rest alphabetically")
    func columnOrder() throws {
        let items = [
            Self.item(["pk": .string("a"), "sk": .number("1"), "zeta": .string("z"), "beta": .string("b")]),
            Self.item(["pk": .string("b"), "alpha": .number("2")])
        ]
        let table = DynamoDBItemTable(items: items, schema: try Self.schema(), preferredColumns: ["zeta", "missing"])
        #expect(table.columns == ["zeta", "missing", "pk", "sk", "alpha", "beta"])
    }

    @Test("A preferred column that is also a key is listed once, where it was preferred")
    func preferredKeyIsNotRepeated() throws {
        let items = [Self.item(["pk": .string("a"), "sk": .number("1"), "note": .string("n")])]
        let table = DynamoDBItemTable(items: items, schema: try Self.schema(), preferredColumns: ["note", "sk"])
        #expect(table.columns == ["note", "sk", "pk"])
    }

    @Test("Every table key is a column even when no item carries it")
    func allKeysIncludedByDefault() throws {
        let table = DynamoDBItemTable(items: [Self.item(["other": .string("x")])], schema: try Self.schema())
        #expect(table.columns == ["pk", "sk", "other"])
        #expect(table.rows == [[.null, .null, .text("x")]])
    }

    @Test("With includeAllKeys off, only the keys some item carries are columns")
    func onlyPresentKeysWhenNotIncludingAll() throws {
        let items = [Self.item(["pk": .string("a"), "other": .string("x")])]
        let table = DynamoDBItemTable(items: items, schema: try Self.schema(), includeAllKeys: false)
        #expect(table.columns == ["pk", "other"])
    }

    @Test("An index key no item carries is not a column")
    func indexKeysAreNotForced() throws {
        let table = DynamoDBItemTable(items: [Self.item(["pk": .string("a")])], schema: try Self.schema())
        #expect(!table.columns.contains("status"))
    }

    @Test("With no schema and no items the table is empty")
    func emptyTable() {
        let table = DynamoDBItemTable(items: [], schema: nil)
        #expect(table.columns.isEmpty)
        #expect(table.rows.isEmpty)
        #expect(table.types.isEmpty)
    }

    @Test("Each row holds its item's cells in column order, with a missing attribute as null")
    func rowsFollowColumns() {
        let items = [
            Self.item(["a": .string("x"), "b": .number("1.50")]),
            Self.item(["b": .bool(true), "c": .map(["k": .number("2")])])
        ]
        let table = DynamoDBItemTable(items: items, schema: nil)
        #expect(table.columns == ["a", "b", "c"])
        #expect(table.rows == [
            [.text("x"), .text("1.50"), .null],
            [.null, .text("true"), .text(#"{"k":2}"#)]
        ])
    }

    @Test("A column takes the type most of its values have, ignoring NULL")
    func majorityType() {
        let items = [
            Self.item(["v": .number("1")]),
            Self.item(["v": .string("x")]),
            Self.item(["v": .number("2")]),
            Self.item(["v": .null]),
            Self.item(["v": .null]),
            Self.item(["v": .null])
        ]
        #expect(DynamoDBItemTable.majorityType(of: "v", in: items) == .number)
        #expect(DynamoDBItemTable(items: items, schema: nil).types == [.number])
    }

    @Test("A column whose values are all NULL or missing has no type")
    func nullOnlyColumnHasNoType() {
        let items = [Self.item(["v": .null]), Self.item(["w": .string("x")])]
        #expect(DynamoDBItemTable.majorityType(of: "v", in: items) == nil)
        #expect(DynamoDBItemTable.majorityType(of: "absent", in: items) == nil)
    }

    @Test("A tie between types resolves the same way whatever order the items arrive in")
    func majorityTieIsDeterministic() {
        let tied = [
            Self.item(["v": .string("x")]),
            Self.item(["v": .number("1")]),
            Self.item(["v": .map([:])]),
            Self.item(["v": .string("y")]),
            Self.item(["v": .number("2")]),
            Self.item(["v": .map([:])])
        ]
        let forward = DynamoDBItemTable.majorityType(of: "v", in: tied)
        let backward = DynamoDBItemTable.majorityType(of: "v", in: tied.reversed())
        let rotated = DynamoDBItemTable.majorityType(of: "v", in: Array(tied[2...] + tied[..<2]))
        #expect(forward != nil)
        #expect(forward == backward)
        #expect(forward == rotated)
        #expect([DynamoDBAttributeType.string, .number, .map].contains(forward ?? .null))
    }

    @Test("Table key columns take their type from the schema, not from the items")
    func keyColumnsTypedFromSchema() throws {
        let items = [
            Self.item(["pk": .number("1"), "sk": .string("not a number")]),
            Self.item(["pk": .number("2"), "sk": .string("still not")])
        ]
        let table = DynamoDBItemTable(items: items, schema: try Self.schema())
        #expect(table.columns == ["pk", "sk"])
        #expect(table.types == [.string, .number])
    }

    @Test("A key column no item carries is still typed from the schema")
    func absentKeyTypedFromSchema() throws {
        let table = DynamoDBItemTable(items: [], schema: try Self.schema())
        #expect(table.columns == ["pk", "sk"])
        #expect(table.typeNames == ["String", "Number"])
    }

    @Test("typeNames uses display names and falls back to String for an untyped column")
    func typeNamesFallBackToString() {
        let items = [Self.item(["n": .numberSet(["1"]), "z": .null])]
        let table = DynamoDBItemTable(items: items, schema: nil, preferredColumns: ["missing"])
        #expect(table.columns == ["missing", "n", "z"])
        #expect(table.typeNames == ["String", "Number Set", "String"])
    }

    @Test("observedTypes lists only the columns that have a type")
    func observedTypesSkipUntyped() {
        let items = [Self.item(["n": .number("1"), "z": .null])]
        let table = DynamoDBItemTable(items: items, schema: nil)
        #expect(table.observedTypes == ["n": .number])
    }

    @Test(
        "Column metadata carries the type the app classifies the column by",
        arguments: [
            ClassificationCase(value: .map(["a": .string("x")]), displayName: "Map", classification: "JSON"),
            ClassificationCase(value: .list([.string("x")]), displayName: "List", classification: "JSON"),
            ClassificationCase(value: .stringSet(["x"]), displayName: "String Set", classification: "JSON"),
            ClassificationCase(value: .numberSet(["1"]), displayName: "Number Set", classification: "JSON"),
            ClassificationCase(value: .binarySet([Data([1])]), displayName: "Binary Set", classification: "JSON"),
            ClassificationCase(value: .number("1"), displayName: "Number", classification: "NUMERIC"),
            ClassificationCase(value: .binary(Data([1])), displayName: "Binary", classification: "BLOB"),
            ClassificationCase(value: .bool(true), displayName: "Boolean", classification: "BOOLEAN"),
            ClassificationCase(value: .string("x"), displayName: "String", classification: "TEXT")
        ]
    )
    func columnMetaClassification(expected: ClassificationCase) throws {
        let table = DynamoDBItemTable(items: [Self.item(["v": expected.value])], schema: nil)
        let meta = try #require(table.columnMeta(schema: nil).first)
        #expect(meta.name == "v")
        #expect(meta.dataType == expected.displayName)
        #expect(meta.classificationTypeName == expected.classification)
        #expect(meta.typeNameForClassification == expected.classification)
    }

    @Test("An untyped column's metadata reads as a String classified as TEXT")
    func untypedColumnMeta() throws {
        let table = DynamoDBItemTable(items: [Self.item(["v": .null])], schema: nil)
        let meta = try #require(table.columnMeta(schema: nil).first)
        #expect(meta.dataType == "String")
        #expect(meta.classificationTypeName == "TEXT")
    }

    @Test("Key columns are primary keys and not nullable, other columns the reverse")
    func columnMetaMarksKeys() throws {
        let schema = try Self.schema()
        let items = [Self.item(["pk": .string("a"), "sk": .number("1"), "status": .string("open")])]
        let meta = DynamoDBItemTable(items: items, schema: schema).columnMeta(schema: schema)
        #expect(meta.map(\.name) == ["pk", "sk", "status"])
        #expect(meta.map(\.isPrimaryKey) == [true, true, false])
        #expect(meta.map(\.isNullable) == [false, false, true])
        #expect(meta.map(\.dataType) == ["String", "Number", "String"])
        #expect(meta.map(\.classificationTypeName) == ["TEXT", "NUMERIC", "TEXT"])
    }

    @Test("Numbers sort by value, not by text")
    func sortsNumbersNumerically() {
        let items = [
            Self.item(["id": .string("a"), "n": .number("10")]),
            Self.item(["id": .string("b"), "n": .number("9")]),
            Self.item(["id": .string("c"), "n": .number("-1")]),
            Self.item(["id": .string("d"), "n": .number("1e1")]),
            Self.item(["id": .string("e"), "n": .number("12345678901234567890123456789012345678")])
        ]
        let ascending = DynamoDBItemTable.sorted(items, by: [DynamoDBOrderTerm(attribute: "n", descending: false)])
        #expect(Self.ids(ascending) == ["c", "b", "a", "d", "e"])
        let descending = DynamoDBItemTable.sorted(items, by: [DynamoDBOrderTerm(attribute: "n", descending: true)])
        #expect(Self.ids(descending) == ["e", "a", "d", "b", "c"])
    }

    @Test("Strings sort by their text")
    func sortsText() {
        let items = [
            Self.item(["id": .string("1"), "s": .string("b")]),
            Self.item(["id": .string("2"), "s": .string("a")]),
            Self.item(["id": .string("3"), "s": .string("C")])
        ]
        let sorted = DynamoDBItemTable.sorted(items, by: [DynamoDBOrderTerm(attribute: "s", descending: false)])
        #expect(Self.ids(sorted) == ["3", "2", "1"])
    }

    @Test("Items missing the attribute sort first ascending and last descending")
    func missingSortsFirst() {
        let items = [
            Self.item(["id": .string("two"), "n": .number("2")]),
            Self.item(["id": .string("none")]),
            Self.item(["id": .string("one"), "n": .number("1")])
        ]
        let ascending = DynamoDBItemTable.sorted(items, by: [DynamoDBOrderTerm(attribute: "n", descending: false)])
        #expect(Self.ids(ascending) == ["none", "one", "two"])
        let descending = DynamoDBItemTable.sorted(items, by: [DynamoDBOrderTerm(attribute: "n", descending: true)])
        #expect(Self.ids(descending) == ["two", "one", "none"])
    }

    @Test("Ties keep the order DynamoDB returned, in both directions")
    func tiesKeepOrder() {
        let items = (0..<8).map { index in
            Self.item(["id": .string("\(index)"), "group": .number(index.isMultiple(of: 2) ? "1" : "1.0")])
        }
        let ascending = DynamoDBItemTable.sorted(items, by: [DynamoDBOrderTerm(attribute: "group", descending: false)])
        let descending = DynamoDBItemTable.sorted(items, by: [DynamoDBOrderTerm(attribute: "group", descending: true)])
        let original = (0..<8).map { "\($0)" }
        #expect(Self.ids(ascending) == original)
        #expect(Self.ids(descending) == original)
    }

    @Test("Later terms break ties left by earlier ones")
    func multipleTerms() {
        let items = [
            Self.item(["id": .string("a"), "g": .string("x"), "n": .number("1")]),
            Self.item(["id": .string("b"), "g": .string("w"), "n": .number("5")]),
            Self.item(["id": .string("c"), "g": .string("x"), "n": .number("3")]),
            Self.item(["id": .string("d"), "g": .string("w"), "n": .number("2")])
        ]
        let order = [
            DynamoDBOrderTerm(attribute: "g", descending: false),
            DynamoDBOrderTerm(attribute: "n", descending: true)
        ]
        #expect(Self.ids(DynamoDBItemTable.sorted(items, by: order)) == ["b", "d", "c", "a"])
    }

    @Test("No order terms leaves the items as they were")
    func noTermsKeepsOrder() {
        let items = (0..<5).map { Self.item(["id": .string("\($0)")]) }
        #expect(Self.ids(DynamoDBItemTable.sorted(items, by: [])) == ["0", "1", "2", "3", "4"])
    }

    @Test("A column mixing Numbers and Strings sorts the same whatever order the items arrive in")
    func mixedTypesSortConsistently() {
        let items = [
            Self.item(["id": .string("nine"), "v": .number("9")]),
            Self.item(["id": .string("ten"), "v": .number("10")]),
            Self.item(["id": .string("text"), "v": .string("5a")])
        ]
        let order = [DynamoDBOrderTerm(attribute: "v", descending: false)]
        let permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        let results = permutations.map { permutation in
            Self.ids(DynamoDBItemTable.sorted(permutation.map { items[$0] }, by: order))
        }
        #expect(Set(results).count == 1, "orders seen: \(results)")
        let first = results.first ?? []
        let nine = first.firstIndex(of: "nine") ?? -1
        let ten = first.firstIndex(of: "ten") ?? -1
        #expect(nine < ten)
    }
}
