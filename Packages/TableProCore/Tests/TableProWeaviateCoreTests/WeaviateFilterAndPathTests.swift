import Foundation
@testable import TableProWeaviateCore
import Testing

private let articleTypes = [
    "title": "text",
    "wordCount": "int",
    "ratio": "number",
    "live": "boolean",
    "published": "date",
    "tags": "text[]",
    "scores": "int[]"
]

private let articleSchema = articleTypes.mapValues { WeaviateProperty(name: "", dataType: $0) }

private func operand(_ column: String, _ op: String, _ value: String, second: String? = nil) throws -> String {
    try WeaviateFilterBuilder.operand(
        for: WeaviateFilterSpec(column: column, op: op, value: value, secondValue: second),
        types: articleTypes
    )
}

@Suite("Weaviate filter value types")
struct WeaviateFilterValueTypeTests {
    @Test("Each data type picks the value field Weaviate demands")
    func valueFieldFollowsDataType() throws {
        #expect(try operand("title", "=", "Hello").contains("valueText: \"Hello\""))
        #expect(try operand("wordCount", "=", "12").contains("valueInt: 12"))
        #expect(try operand("ratio", ">", "1.5").contains("valueNumber: 1.5"))
        #expect(try operand("live", "=", "true").contains("valueBoolean: true"))
        #expect(try operand("published", ">", "2024-01-31T00:00:00Z")
            .contains("valueDate: \"2024-01-31T00:00:00Z\""))
    }

    @Test("An array property filters on its element type")
    func arrayUsesElementField() throws {
        #expect(try operand("tags", "=", "alpha").contains("valueText: \"alpha\""))
        #expect(try operand("scores", "=", "3").contains("valueInt: 3"))
    }

    @Test("The uuid column filters as text on the id path")
    func uuidFiltersAsText() throws {
        let clause = try operand(WeaviateSchema.uuidColumn, "=", "c8f5c3e0-1b2a-4d3e-9f10-111213141516")
        #expect(clause.contains("path: [\"id\"]"))
        #expect(clause.contains("valueText:"))
    }

    @Test("A value that is not a number is refused instead of becoming zero")
    func badNumberThrows() {
        #expect(throws: WeaviateFilterError.notANumber(column: "wordCount", value: "abc")) {
            _ = try operand("wordCount", "=", "abc")
        }
        #expect(throws: WeaviateFilterError.notANumber(column: "ratio", value: "abc")) {
            _ = try operand("ratio", "=", "abc")
        }
    }

    @Test("A value that is not a boolean is refused instead of becoming false")
    func badBooleanThrows() {
        #expect(throws: WeaviateFilterError.notABoolean(column: "live", value: "yes")) {
            _ = try operand("live", "=", "yes")
        }
    }

    @Test("A date needs a full RFC 3339 timestamp")
    func badDateThrows() {
        #expect(throws: WeaviateFilterError.notADate(column: "published", value: "2024-01-31")) {
            _ = try operand("published", ">", "2024-01-31")
        }
        #expect(WeaviateDateLiteral.isRFC3339("2024-01-31T00:00:00+07:00"))
        #expect(WeaviateDateLiteral.isRFC3339("2024-01-31T00:00:00.123Z"))
    }
}

@Suite("Weaviate filter operators")
struct WeaviateFilterOperatorTests {
    @Test("Substring operators become Like patterns")
    func likePatterns() throws {
        #expect(try operand("title", "CONTAINS", "ell").contains("operator: Like valueText: \"*ell*\""))
        #expect(try operand("title", "STARTS WITH", "He").contains("valueText: \"He*\""))
        #expect(try operand("title", "ENDS WITH", "lo").contains("valueText: \"*lo\""))
        #expect(try operand("title", "NOT CONTAINS", "ell").hasPrefix("{ operator: Not operands: ["))
    }

    @Test("IN and NOT IN become ContainsAny")
    func listOperators() throws {
        let inClause = try operand("wordCount", "IN", "10, 30")
        #expect(inClause.contains("operator: ContainsAny valueInt: [10, 30]"))
        let notIn = try operand("title", "NOT IN", "a,b")
        #expect(notIn.contains("operator: ContainsNone valueText: [\"a\", \"b\"]"))
    }

    @Test("IN with no values is refused")
    func emptyListThrows() {
        #expect(throws: WeaviateFilterError.emptyList(column: "title")) {
            _ = try operand("title", "IN", " , ")
        }
    }

    @Test("BETWEEN becomes a bounded And and needs its upper bound")
    func betweenBounds() throws {
        let clause = try operand("wordCount", "BETWEEN", "5", second: "10")
        #expect(clause.hasPrefix("{ operator: And operands: ["))
        #expect(clause.contains("operator: GreaterThanEqual valueInt: 5"))
        #expect(clause.contains("operator: LessThanEqual valueInt: 10"))

        #expect(throws: WeaviateFilterError.missingUpperBound(column: "wordCount")) {
            _ = try operand("wordCount", "BETWEEN", "5")
        }
    }

    @Test("IS NULL maps to IsNull in both directions")
    func nullOperators() throws {
        #expect(try operand("title", "IS NULL", "").contains("operator: IsNull valueBoolean: true"))
        #expect(try operand("title", "IS NOT NULL", "").contains("operator: IsNull valueBoolean: false"))
    }

    @Test("An operator Weaviate cannot express is reported, not dropped")
    func unsupportedOperatorsThrow() {
        #expect(throws: WeaviateFilterError.unsupportedOperator("REGEX")) {
            _ = try operand("title", "REGEX", "^a")
        }
    }

    @Test("Emptiness counts with len(), which is what Weaviate offers")
    func emptinessUsesLength() throws {
        #expect(try operand("title", "IS EMPTY", "")
            .contains("path: [\"len(title)\"] operator: Equal valueInt: 0"))
        #expect(try operand("title", "IS NOT EMPTY", "")
            .contains("path: [\"len(title)\"] operator: GreaterThan valueInt: 0"))
        #expect(throws: WeaviateFilterError.textMatchNeedsText(column: "wordCount", op: "IS EMPTY")) {
            _ = try operand("wordCount", "IS EMPTY", "")
        }
    }

    @Test("Comparing text, and matching a number as text, are both refused")
    func mismatchedOperatorsThrow() {
        #expect(throws: WeaviateFilterError.comparisonNeedsNumberOrDate(column: "title", op: ">")) {
            _ = try operand("title", ">", "Row 1")
        }
        #expect(throws: WeaviateFilterError.textMatchNeedsText(column: "wordCount", op: "CONTAINS")) {
            _ = try operand("wordCount", "CONTAINS", "1")
        }
    }

    @Test("The vector column cannot be filtered")
    func vectorFilterThrows() {
        #expect(throws: WeaviateFilterError.vectorNotFilterable(column: "vector")) {
            _ = try operand(WeaviateSchema.vectorColumn, "=", "[1,2]")
        }
    }

    @Test("A quote in a value cannot break out of the GraphQL string")
    func valuesAreEscaped() throws {
        let clause = try operand("title", "=", "a\"b\\c")
        #expect(clause.contains("valueText: \"a\\\"b\\\\c\""))
    }

    @Test("Several filters join under one logic operator")
    func logicMode() throws {
        let built = try WeaviateFilterBuilder.graphQLWhere(
            filters: [
                WeaviateFilterSpec(column: "title", op: "=", value: "a"),
                WeaviateFilterSpec(column: "wordCount", op: ">", value: "3")
            ],
            logicMode: "OR",
            types: articleTypes
        )
        let clause = try #require(built)
        #expect(clause.hasPrefix("{ operator: Or operands: ["))
    }
}

@Suite("Weaviate sorting")
struct WeaviateSortTests {
    @Test("A uuid sort reaches GraphQL, which can sort by the object id")
    func uuidSortUsesGraphQL() throws {
        let encoded = WeaviateBrowseQuery.encode(
            collection: "Article",
            offset: 0,
            limit: 25,
            sorts: [WeaviateSortSpec(column: WeaviateSchema.uuidColumn, ascending: false)],
            filters: [],
            logicMode: "AND",
            propertyNames: ["uuid", "title"]
        )
        let parsed = try #require(WeaviateBrowseQuery.parse(encoded))
        #expect(parsed.usesGraphQL)

        let query = try WeaviateGraphQL.getQuery(
            collection: "Article",
            properties: parsed.propertyNames,
            limit: parsed.limit,
            offset: parsed.offset,
            sorts: parsed.sortableSorts,
            filters: [],
            logicMode: "AND",
            schema: articleSchema
        )
        #expect(query.contains("sort: [{ path: [\"id\"] order: desc }]"))
    }

    @Test("A vector sort is dropped, because Weaviate has no such property")
    func vectorSortIsDropped() throws {
        let encoded = WeaviateBrowseQuery.encode(
            collection: "Article",
            offset: 0,
            limit: 25,
            sorts: [WeaviateSortSpec(column: WeaviateSchema.vectorColumn, ascending: true)],
            filters: [],
            logicMode: "AND",
            propertyNames: ["uuid", "vector"]
        )
        let parsed = try #require(WeaviateBrowseQuery.parse(encoded))
        #expect(parsed.sortableSorts.isEmpty)
        #expect(!parsed.usesGraphQL)
    }

    @Test("BETWEEN survives the browse tag round-trip")
    func secondValueRoundTrips() throws {
        let encoded = WeaviateBrowseQuery.encode(
            collection: "Article",
            offset: 0,
            limit: 25,
            sorts: [],
            filters: [WeaviateFilterSpec(column: "wordCount", op: "BETWEEN", value: "5", secondValue: "10")],
            logicMode: "AND",
            propertyNames: ["uuid"]
        )
        let parsed = try #require(WeaviateBrowseQuery.parse(encoded))
        #expect(parsed.filters.first?.secondValue == "10")
    }
}

@Suite("Weaviate request paths")
struct WeaviatePathTests {
    private let base = URL(string: "http://localhost:8080")!

    @Test("A console path keeps its query string instead of encoding the question mark")
    func consoleQueryStringSurvives() throws {
        let url = try #require(
            WeaviatePathEncoding.resolve("/v1/objects?class=Article&limit=10", against: base)
        )
        #expect(url.path == "/v1/objects")
        #expect(!url.absoluteString.contains("%3F"))
        #expect(url.query == "class=Article&limit=10")
    }

    @Test("A path and passed query items merge")
    func mergedQueryItems() throws {
        let url = try #require(
            WeaviatePathEncoding.resolve("/v1/objects?class=Article", query: ["limit": "5"], against: base)
        )
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "class", value: "Article")))
        #expect(items.contains(URLQueryItem(name: "limit", value: "5")))
    }

    @Test("An already-encoded segment is not encoded twice")
    func encodedSegmentSurvives() throws {
        let uuid = "c8f5c3e0-1b2a-4d3e-9f10-111213141516"
        let url = try #require(
            WeaviatePathEncoding.resolve("/v1/objects/\(WeaviatePathEncoding.segment(uuid))", against: base)
        )
        #expect(url.path == "/v1/objects/\(uuid)")
    }

    @Test("An absolute or relative path is refused")
    func hostiledPathsRefused() {
        #expect(WeaviatePathEncoding.resolve("http://evil.example/v1", against: base) == nil)
        #expect(WeaviatePathEncoding.resolve("v1/schema", against: base) == nil)
    }
}

@Suite("Weaviate response decoding")
struct WeaviateResponseDecodingTests {
    @Test("A vector component at the edge of Int does not trap")
    func hugeVectorComponent() {
        let object = WeaviateObject(
            uuid: "u1",
            className: "Article",
            properties: [:],
            vector: [9_223_372_036_854_775_808.0, 1.5]
        )
        let text = object.vectorText
        #expect(text?.hasPrefix("[9.223372036854776e+18") == true)
        #expect(text?.hasSuffix("1.5]") == true)
    }

    @Test("A Get row keeps the _additional fields a vector search returns")
    func additionalFieldsBecomeColumns() {
        let objects = WeaviateObjectCodec.objects(fromGraphQL: [
            "data": [
                "Get": [
                    "Article": [
                        [
                            "title": "Hello",
                            "_additional": ["id": "u1", "distance": 0.42, "score": "0.9"]
                        ]
                    ]
                ]
            ]
        ])
        let object = objects.first
        #expect(object?.uuid == "u1")
        #expect(object?.properties["title"] == "Hello")
        #expect(object?.properties["distance"] == "0.42")
        #expect(object?.properties["score"] == "0.9")
    }

    @Test("A property keeps its name when _additional carries the same one")
    func propertyWinsOverAdditional() {
        let objects = WeaviateObjectCodec.objects(fromGraphQL: [
            "data": ["Get": ["Article": [["distance": "mine", "_additional": ["id": "u1", "distance": 0.42]]]]]
        ])
        #expect(objects.first?.properties["distance"] == "mine")
        #expect(objects.first?.properties["_additional.distance"] == "0.42")
    }

    @Test("A response body is parsed once and still compares by its bytes")
    func responseEquality() {
        let body = Data(#"{"a":1}"#.utf8)
        let first = WeaviateHTTPResponse(statusCode: 200, body: body)
        let second = WeaviateHTTPResponse(statusCode: 200, body: body)
        #expect(first == second)
        #expect(WeaviateJSON.dictionary(first.json)?["a"] as? Int == 1)
        #expect(WeaviateJSON.dictionary(first.json)?["a"] as? Int == 1)
        #expect(first != WeaviateHTTPResponse(statusCode: 500, body: body))
    }
}

@Suite("Weaviate write generation")
struct WeaviateWriteGenerationTests {
    @Test("A duplicate column name does not trap the generator")
    func duplicateColumnNames() throws {
        let batch = WeaviateStatementGenerator.generate(
            collection: "Article",
            columns: ["uuid", "title", "title"],
            typeNames: ["uuid", "text", "int"],
            changes: [
                WeaviateTrackedChange(
                    kind: .update,
                    uuid: "c8f5c3e0-1b2a-4d3e-9f10-111213141516",
                    values: [:],
                    cellChanges: [WeaviateCellChange(column: "title", newText: "Edited")]
                )
            ]
        )
        let body = try #require(batch.requests.first?.body)
        #expect(body.contains("\"title\":\"Edited\""))
    }

    @Test("A delete with no uuid is reported rather than dropped in silence")
    func deleteWithoutUUIDIsReported() {
        let batch = WeaviateStatementGenerator.generate(
            collection: "Article",
            columns: ["uuid", "title"],
            typeNames: ["uuid", "text"],
            changes: [WeaviateTrackedChange(kind: .delete, uuid: nil, values: [:], cellChanges: [])]
        )
        #expect(batch.requests.isEmpty)
        #expect(batch.skipped == [WeaviateSkippedChange(kind: .delete, reason: .missingUUID)])
    }

    @Test("An update touching only read-only columns is reported")
    func updateWithNoEditableColumns() {
        let batch = WeaviateStatementGenerator.generate(
            collection: "Article",
            columns: ["uuid", "vector"],
            typeNames: ["uuid", "vector"],
            changes: [
                WeaviateTrackedChange(
                    kind: .update,
                    uuid: "c8f5c3e0-1b2a-4d3e-9f10-111213141516",
                    values: [:],
                    cellChanges: [WeaviateCellChange(column: "vector", newText: "[1,2]")]
                )
            ]
        )
        #expect(batch.requests.isEmpty)
        #expect(batch.skipped == [WeaviateSkippedChange(kind: .update, reason: .noEditableColumns)])
    }
}


@Suite("Weaviate selection sets")
struct WeaviateSelectionSetTests {
    private func query(_ properties: [WeaviateProperty]) throws -> String {
        try WeaviateGraphQL.getQuery(
            collection: "Article",
            properties: properties.map(\.name),
            limit: 5,
            offset: 0,
            sorts: [],
            filters: [],
            logicMode: "AND",
            schema: Dictionary(properties.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }

    @Test("A structured property asks for its own fields instead of failing the query")
    func structuredPropertiesGetSubSelections() throws {
        let built = try query([
            WeaviateProperty(name: "title", dataType: "text"),
            WeaviateProperty(name: "place", dataType: "geoCoordinates"),
            WeaviateProperty(name: "phone", dataType: "phoneNumber")
        ])
        #expect(built.contains("place { latitude longitude }"))
        #expect(built.contains("phone { input internationalFormatted"))
        #expect(built.contains(" title "))
    }

    @Test("An object property selects its declared nested properties")
    func objectSelectsNested() throws {
        let built = try query([
            WeaviateProperty(
                name: "meta",
                dataTypes: ["object"],
                nestedProperties: [
                    WeaviateProperty(name: "k", dataType: "text"),
                    WeaviateProperty(name: "inner", dataTypes: ["object"], nestedProperties: [
                        WeaviateProperty(name: "deep", dataType: "int")
                    ])
                ]
            )
        ])
        #expect(built.contains("meta { k inner { deep } }"))
    }

    @Test("An object with no declared nested properties is left out")
    func emptyObjectIsOmitted() throws {
        let built = try query([
            WeaviateProperty(name: "title", dataType: "text"),
            WeaviateProperty(name: "meta", dataTypes: ["object"], nestedProperties: [])
        ])
        #expect(!built.contains("meta"))
        #expect(built.contains("title"))
    }

    @Test("A cross-reference asks for the referenced ids")
    func crossReferenceUsesFragments() throws {
        let built = try query([
            WeaviateProperty(name: "category", dataTypes: ["Category", "Topic"], nestedProperties: [])
        ])
        #expect(built.contains("category { ... on Category { _additional { id } } ... on Topic { _additional { id } } }"))
    }

    @Test("A nested property list survives schema parsing")
    func schemaParsesNestedProperties() throws {
        let collections = WeaviateSchema.collections(from: [
            "classes": [[
                "class": "Article",
                "properties": [
                    ["name": "meta", "dataType": ["object"], "nestedProperties": [["name": "k", "dataType": ["text"]]]],
                    ["name": "category", "dataType": ["Category"]]
                ]
            ]]
        ])
        let properties = try #require(collections.first?.properties)
        #expect(properties.first?.nestedProperties.map(\.name) == ["k"])
        #expect(WeaviatePropertyShape.of(properties[1]) == .crossReference(["Category"]))
    }
}

@Suite("Weaviate value round-trip")
struct WeaviateParsedValueTests {
    @Test("Text keeps its own punctuation instead of being parsed as JSON")
    func textStaysText() {
        #expect(WeaviateJSON.parsedValue("{\"a\":1}", typeName: "text") as? String == "{\"a\":1}")
        #expect(WeaviateJSON.parsedValue("[1,2]", typeName: "text") as? String == "[1,2]")
        #expect(WeaviateJSON.parsedValue("{\"a\":1}", typeName: "string") as? String == "{\"a\":1}")
        #expect(WeaviateJSON.parsedValue("2024-01-31T00:00:00Z", typeName: "date") as? String == "2024-01-31T00:00:00Z")
    }

    @Test("A type the grid renders as JSON parses back")
    func structuredParsesBack() {
        #expect(WeaviateJSON.parsedValue("[\"a\",\"b\"]", typeName: "text[]") as? [String] == ["a", "b"])
        #expect(WeaviateJSON.parsedValue("[1,2]", typeName: "int[]") as? [Int] == [1, 2])
        let object = WeaviateJSON.parsedValue("{\"k\":\"v\"}", typeName: "object") as? [String: Any]
        #expect(object?["k"] as? String == "v")
        let geo = WeaviateJSON.parsedValue("{\"latitude\":1}", typeName: "geoCoordinates") as? [String: Any]
        #expect(geo?["latitude"] as? Int == 1)
    }

    @Test("A scalar parses to its own type, and an unparsable one stays text")
    func scalarsParse() {
        #expect(WeaviateJSON.parsedValue("12", typeName: "int") as? Int == 12)
        #expect(WeaviateJSON.parsedValue("1.5", typeName: "number") as? Double == 1.5)
        #expect(WeaviateJSON.parsedValue("true", typeName: "boolean") as? Bool == true)
        #expect(WeaviateJSON.parsedValue("abc", typeName: "int") as? String == "abc")
        #expect(WeaviateJSON.parsedValue("yes", typeName: "boolean") as? String == "yes")
    }

    @Test("A property named with a leading underscore is written, and a synthetic column is not")
    func underscoreNamedPropertyIsWritten() throws {
        let batch = WeaviateStatementGenerator.generate(
            collection: "Event",
            columns: ["uuid", "_source", "distance"],
            typeNames: ["uuid", "text", "number"],
            changes: [
                WeaviateTrackedChange(
                    kind: .update,
                    uuid: "c8f5c3e0-1b2a-4d3e-9f10-111213141516",
                    values: [:],
                    cellChanges: [
                        WeaviateCellChange(column: "_source", newText: "manual"),
                        WeaviateCellChange(column: "_additional.distance", newText: "0.4")
                    ]
                )
            ]
        )
        let body = try #require(batch.requests.first?.body)
        #expect(body.contains("\"_source\":\"manual\""))
        #expect(!body.contains("_additional"))
    }
}

@Suite("Weaviate console requests")
struct WeaviateConsoleRequestTests {
    @Test("A body typed on the request line is kept")
    func inlineBodySurvives() throws {
        let request = try #require(
            WeaviateConsoleParser.parse("POST /v1/objects {\"class\": \"Article\"}")
        )
        #expect(request.method == "POST")
        #expect(request.path == "/v1/objects")
        #expect(request.body == "{\"class\": \"Article\"}")
    }

    @Test("A body on the lines below still wins")
    func multilineBodyWins() throws {
        let request = try #require(WeaviateConsoleParser.parse("POST /v1/graphql\n{ \"query\": \"x\" }"))
        #expect(request.body == "{ \"query\": \"x\" }")
    }

    @Test("Any path is resolved under /v1")
    func everyPathIsPrefixed() throws {
        #expect(try #require(WeaviateConsoleParser.parse("GET /nodes")).path == "/v1/nodes")
        #expect(try #require(WeaviateConsoleParser.parse("POST /batch/objects")).path == "/v1/batch/objects")
        #expect(try #require(WeaviateConsoleParser.parse("GET /v1/schema")).path == "/v1/schema")
        #expect(try #require(WeaviateConsoleParser.parse("GET /")).path == "/")
    }

    @Test("SQL is still not a console request")
    func sqlIsRefused() {
        #expect(WeaviateConsoleParser.parse("DELETE FROM Article") == nil)
        #expect(WeaviateConsoleParser.parse("UPDATE Article SET title = 'x'") == nil)
    }

    @Test("A browse that is not showing the vector does not ask for it")
    func vectorIsOptional() throws {
        let withVector = try WeaviateGraphQL.getQuery(
            collection: "Article", properties: ["uuid", "title"], limit: 5, offset: 0,
            sorts: [], filters: [], logicMode: "AND", schema: [:], includeVector: true
        )
        let withoutVector = try WeaviateGraphQL.getQuery(
            collection: "Article", properties: ["uuid", "title"], limit: 5, offset: 0,
            sorts: [], filters: [], logicMode: "AND", schema: [:], includeVector: false
        )
        #expect(withVector.contains("_additional { id vector }"))
        #expect(withoutVector.contains("_additional { id }"))
        #expect(!withoutVector.contains("vector"))
    }
}
