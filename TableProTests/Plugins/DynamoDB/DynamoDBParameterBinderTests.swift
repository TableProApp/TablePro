import Foundation
import TableProPluginKit
import Testing

struct DynamoDBParameterBinderTests {
    struct KeyCase: Sendable, CustomTestStringConvertible {
        let role: DynamoDBPartiQL.ParameterRole
        let cell: PluginCellValue
        let expected: DynamoDBAttributeValue

        var testDescription: String { "\(role) \(cell)" }
    }

    struct MissingKeyCase: Sendable, CustomTestStringConvertible {
        let role: DynamoDBPartiQL.ParameterRole
        let cell: PluginCellValue

        var testDescription: String { "\(role) \(cell)" }
    }

    static let digest = Data([0x00, 0x01, 0x02])

    static let keyCases: [KeyCase] = [
        KeyCase(role: .compared(DynamoDBAttributePath(attribute: "sk")), cell: "7", expected: .number("7")),
        KeyCase(role: .compared(DynamoDBAttributePath(attribute: "sk")), cell: " -1.5E3 ", expected: .number("-1.5E3")),
        KeyCase(role: .inserted("sk"), cell: "42", expected: .number("42")),
        KeyCase(role: .compared(DynamoDBAttributePath(attribute: "pk")), cell: "7", expected: .string("7")),
        KeyCase(role: .inserted("pk"), cell: "02134", expected: .string("02134")),
        KeyCase(role: .compared(DynamoDBAttributePath(attribute: "rank")), cell: "3", expected: .number("3")),
        KeyCase(role: .compared(DynamoDBAttributePath(attribute: "digest")), cell: .bytes(digest), expected: .binary(digest)),
        KeyCase(role: .compared(DynamoDBAttributePath(attribute: "digest")), cell: "AAEC", expected: .binary(digest)),
        KeyCase(role: .inserted("digest"), cell: .bytes(digest), expected: .binary(digest))
    ]

    static let missingKeyCases: [MissingKeyCase] = [
        MissingKeyCase(role: .compared(DynamoDBAttributePath(attribute: "pk")), cell: .null),
        MissingKeyCase(role: .compared(DynamoDBAttributePath(attribute: "pk")), cell: ""),
        MissingKeyCase(role: .compared(DynamoDBAttributePath(attribute: "pk")), cell: "__DEFAULT__"),
        MissingKeyCase(role: .inserted("pk"), cell: .null),
        MissingKeyCase(role: .inserted("pk"), cell: ""),
        MissingKeyCase(role: .inserted("sk"), cell: "__DEFAULT__"),
        MissingKeyCase(role: .inserted("rank"), cell: "")
    ]

    private static func schema() throws -> DynamoDBTableSchema {
        try DynamoDBTableSchema(describeTableResponse: DynamoDBJSON.parse("""
            {"Table": {
              "TableName": "Orders",
              "KeySchema": [
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"}
              ],
              "AttributeDefinitions": [
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "N"},
                {"AttributeName": "digest", "AttributeType": "B"},
                {"AttributeName": "rank", "AttributeType": "N"}
              ],
              "GlobalSecondaryIndexes": [{
                "IndexName": "ByDigest",
                "KeySchema": [
                  {"AttributeName": "digest", "KeyType": "HASH"},
                  {"AttributeName": "rank", "KeyType": "RANGE"}
                ],
                "Projection": {"ProjectionType": "ALL"}
              }]
            }}
            """))
    }

    private func binder(
        observedTypes: [String: DynamoDBAttributeType] = [:],
        currentItem: DynamoDBItem? = nil
    ) throws -> DynamoDBParameterBinder {
        DynamoDBParameterBinder(schema: try Self.schema(), observedTypes: observedTypes, currentItem: currentItem)
    }

    private func bound(
        _ cell: PluginCellValue,
        as role: DynamoDBPartiQL.ParameterRole,
        by binder: DynamoDBParameterBinder
    ) throws -> DynamoDBAttributeValue {
        let values = try binder.bind([cell], roles: [role])
        #expect(values.count == 1)
        return try #require(values.first)
    }

    private func refusedAttribute(
        _ cell: PluginCellValue,
        as role: DynamoDBPartiQL.ParameterRole,
        by binder: DynamoDBParameterBinder
    ) -> String? {
        do {
            _ = try binder.bind([cell], roles: [role])
            return nil
        } catch DynamoDBError.invalidValue(let attribute, _) {
            return attribute
        } catch {
            return nil
        }
    }

    // MARK: - Keys

    @Test("A key attribute takes the type its schema declares", arguments: keyCases)
    func keyIsTypedFromSchema(keyCase: KeyCase) throws {
        let observedAsString = Dictionary(uniqueKeysWithValues: ["pk", "sk", "digest", "rank"].map {
            ($0, DynamoDBAttributeType.string)
        })
        let binder = try binder(
            observedTypes: observedAsString,
            currentItem: ["sk": .string("x"), "rank": .string("y")]
        )
        #expect(try bound(keyCase.cell, as: keyCase.role, by: binder) == keyCase.expected)
    }

    @Test("A Number key that is not a number is refused", arguments: ["seven", "1,5", "NaN", "1e200"])
    func invalidNumberKeyIsRefused(text: String) throws {
        #expect(refusedAttribute(.text(text), as: .compared(DynamoDBAttributePath(attribute: "sk")), by: try binder()) == "sk")
    }

    @Test("A key with no value is refused", arguments: missingKeyCases)
    func missingKeyIsRefused(missingKeyCase: MissingKeyCase) throws {
        let attribute: String
        switch missingKeyCase.role {
        case .compared(let path), .assigned(let path):
            attribute = path.root
        case .inserted(let name):
            attribute = name
        case .unknown:
            attribute = ""
        }
        #expect(refusedAttribute(missingKeyCase.cell, as: missingKeyCase.role, by: try binder()) == attribute)
    }

    @Test("Bytes are refused for a key that is not Binary")
    func bytesForNonBinaryKeyAreRefused() throws {
        let binder = try binder()
        #expect(refusedAttribute(.bytes(Self.digest), as: .compared(DynamoDBAttributePath(attribute: "pk")), by: binder) == "pk")
        #expect(refusedAttribute(.bytes(Self.digest), as: .inserted("sk"), by: binder) == "sk")
    }

    @Test("A Binary key that is not base64 is refused")
    func invalidBinaryKeyIsRefused() throws {
        #expect(refusedAttribute("not base64!", as: .compared(DynamoDBAttributePath(attribute: "digest")), by: try binder()) == "digest")
    }

    @Test("Assigning a table key is refused", arguments: ["pk", "sk"])
    func assigningKeyIsRefused(attribute: String) throws {
        #expect(refusedAttribute("new", as: .assigned(DynamoDBAttributePath(attribute: attribute)), by: try binder()) == attribute)
    }

    @Test("An assigned index key takes the type its schema declares")
    func assignedIndexKeyIsTypedFromSchema() throws {
        #expect(try bound("5", as: .assigned(DynamoDBAttributePath(attribute: "rank")), by: try binder()) == .number("5"))
    }

    // MARK: - Other attributes

    @Test("Assigned and compared attributes take the type of the item's current value")
    func currentValueDecidesType() throws {
        let binder = try binder(
            observedTypes: ["total": .string, "tags": .string, "active": .string],
            currentItem: ["total": .number("10"), "tags": .stringSet(["a"]), "active": .bool(true)]
        )
        #expect(try bound("12", as: .assigned(DynamoDBAttributePath(attribute: "total")), by: binder) == .number("12"))
        #expect(try bound("10", as: .compared(DynamoDBAttributePath(attribute: "total")), by: binder) == .number("10"))
        #expect(try bound("[\"b\", \"c\"]", as: .assigned(DynamoDBAttributePath(attribute: "tags")), by: binder) == .stringSet(["b", "c"]))
        #expect(try bound("false", as: .compared(DynamoDBAttributePath(attribute: "active")), by: binder) == .bool(false))
    }

    @Test("Without a current value, the type observed for the column is used")
    func observedTypeDecidesType() throws {
        let binder = try binder(
            observedTypes: ["total": .number, "flag": .boolean],
            currentItem: ["other": .string("x")]
        )
        #expect(try bound("12", as: .assigned(DynamoDBAttributePath(attribute: "total")), by: binder) == .number("12"))
        #expect(try bound("12", as: .compared(DynamoDBAttributePath(attribute: "total")), by: binder) == .number("12"))
        #expect(try bound("true", as: .inserted("flag"), by: binder) == .bool(true))
    }

    @Test("With no type anywhere, text is a String even when it looks like a number")
    func untypedTextIsString() throws {
        let binder = try binder()
        #expect(try bound("02134", as: .assigned(DynamoDBAttributePath(attribute: "zip")), by: binder) == .string("02134"))
        #expect(try bound("12", as: .compared(DynamoDBAttributePath(attribute: "count")), by: binder) == .string("12"))
        #expect(try bound("true", as: .inserted("flag"), by: binder) == .string("true"))
    }

    @Test("Text that does not fit the current value's type is refused")
    func mismatchedTextIsRefused() throws {
        let binder = try binder(currentItem: ["total": .number("10")])
        #expect(refusedAttribute("ten", as: .assigned(DynamoDBAttributePath(attribute: "total")), by: binder) == "total")
    }

    @Test("A NULL cell for a plain attribute binds as NULL and bytes as Binary")
    func nullAndBytesForPlainAttribute() throws {
        let binder = try binder(currentItem: ["total": .number("10")])
        #expect(try bound(.null, as: .assigned(DynamoDBAttributePath(attribute: "total")), by: binder) == .null)
        #expect(try bound(.bytes(Self.digest), as: .assigned(DynamoDBAttributePath(attribute: "total")), by: binder) == .binary(Self.digest))
    }

    @Test("Without a schema a key name gets no key typing")
    func noSchemaMeansNoKeyTyping() throws {
        let binder = DynamoDBParameterBinder(schema: nil, observedTypes: [:], currentItem: nil)
        #expect(try bound("7", as: .compared(DynamoDBAttributePath(attribute: "sk")), by: binder) == .string("7"))
        #expect(try bound("7", as: .assigned(DynamoDBAttributePath(attribute: "sk")), by: binder) == .string("7"))
    }

    // MARK: - Unknown role

    @Test("A parameter of unknown role binds text as S, bytes as B and NULL as NULL")
    func unknownRole() throws {
        let binder = try binder(observedTypes: ["sk": .number], currentItem: ["sk": .number("1")])
        #expect(try bound("42", as: .unknown, by: binder) == .string("42"))
        #expect(try bound("", as: .unknown, by: binder) == .string(""))
        #expect(try bound(.bytes(Self.digest), as: .unknown, by: binder) == .binary(Self.digest))
        #expect(try bound(.null, as: .unknown, by: binder) == .null)
    }

    @Test("Parameters beyond the roles read from the statement bind as unknown")
    func extraParametersAreUnknown() throws {
        let values = try binder().bind(["7", "8", .null], roles: [.compared(DynamoDBAttributePath(attribute: "sk"))])
        #expect(values == [.number("7"), .string("8"), .null])
    }

    @Test("Parameters bind in order against their own roles")
    func parametersBindInOrder() throws {
        let binder = try binder(currentItem: ["total": .number("10")])
        let values = try binder.bind(
            ["11", "p1", "7", "10"],
            roles: [
                .assigned(DynamoDBAttributePath(attribute: "total")),
                .compared(DynamoDBAttributePath(attribute: "pk")),
                .compared(DynamoDBAttributePath(attribute: "sk")),
                .compared(DynamoDBAttributePath(attribute: "total"))
            ]
        )
        #expect(values == [.number("11"), .string("p1"), .number("7"), .number("10")])
    }
}
