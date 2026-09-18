import Foundation
import TableProGoogleCloud
import TableProPluginKit
import Testing

private func encodedJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try #require(String(bytes: try encoder.encode(value), encoding: .utf8))
}

@Suite("BigQuery placeholder binding")
struct BigQueryPlaceholderBindingTests {
    @Test("Question marks become numbered named parameters")
    func rewritesPlaceholders() throws {
        let bound = try BigQueryQueryParameters.bind("UPDATE t SET a = ? WHERE b = ?", parameters: ["x", "y"])
        #expect(bound.sql == "UPDATE t SET a = @p1 WHERE b = @p2")
        #expect(bound.bindings.map(\.name) == ["p1", "p2"])
        #expect(bound.bindings.map(\.value) == ["x", "y"])
    }

    @Test("A NULL parameter is written as the NULL keyword and not bound")
    func inlinesNull() throws {
        let bound = try BigQueryQueryParameters.bind("INSERT INTO t (a, b, c) VALUES (?, ?, ?)", parameters: ["1", .null, "3"])
        #expect(bound.sql == "INSERT INTO t (a, b, c) VALUES (@p1, NULL, @p3)")
        #expect(bound.bindings.map(\.name) == ["p1", "p3"])
        #expect(bound.bindings.map(\.position) == [1, 3])
    }

    @Test("Question marks inside literals, identifiers and comments stay put")
    func skipsQuotedQuestionMarks() throws {
        let sql = "SELECT '?', \"?\", `a?` FROM t -- ?\nWHERE x = ? # ?\n/* ? */"
        let bound = try BigQueryQueryParameters.bind(sql, parameters: ["v"])
        #expect(bound.sql == "SELECT '?', \"?\", `a?` FROM t -- ?\nWHERE x = @p1 # ?\n/* ? */")
    }

    @Test("A backslash-escaped quote does not end the literal early")
    func respectsBackslashEscapes() throws {
        let bound = try BigQueryQueryParameters.bind("SELECT 'it\\'s ?' WHERE a = ?", parameters: ["v"])
        #expect(bound.sql == "SELECT 'it\\'s ?' WHERE a = @p1")
    }

    @Test("A placeholder count that does not match the values throws")
    func countMismatchThrows() {
        #expect(throws: SQLPlaceholderRewriteError.countMismatch(found: 1, expected: 2)) {
            try BigQueryQueryParameters.bind("SELECT ?", parameters: ["a", "b"])
        }
    }

    @Test("The mismatch surfaces as a localized driver error")
    func countMismatchWraps() {
        let wrapped = BigQueryError.wrap(SQLPlaceholderRewriteError.countMismatch(found: 3, expected: 1))
        guard case BigQueryError.placeholderCount(let found, let expected)? = wrapped as? BigQueryError else {
            Issue.record("Expected a placeholder count error")
            return
        }
        #expect(found == 3)
        #expect(expected == 1)
    }
}

@Suite("BigQuery query parameter encoding")
struct BigQueryQueryParameterEncodingTests {
    private func parameter(
        _ value: PluginCellValue,
        type: BigQueryParameterType?
    ) throws -> BigQueryQueryParameter {
        let binding = BigQueryParameterBinding(name: "p1", position: 1, value: value)
        let types = type.map { ["p1": $0] } ?? [:]
        let parameters = try BigQueryQueryParameters.queryParameters(for: [binding], types: types)
        return try #require(parameters.first)
    }

    @Test("A scalar is sent as its text")
    func scalarAsText() throws {
        let encoded = try encodedJSON(parameter("42", type: BigQueryParameterType(type: "INT64")))
        #expect(encoded == #"{"name":"p1","parameterType":{"type":"INT64"},"parameterValue":{"value":"42"}}"#)
    }

    @Test("TIMESTAMP, BOOL, NUMERIC and JSON values are passed through as strings")
    func stringTypedScalars() throws {
        for (type, value) in [
            ("TIMESTAMP", "2021-04-01 00:00:00.000000+00:00"),
            ("BOOL", "true"),
            ("NUMERIC", "12.50"),
            ("JSON", #"{"a":1}"#)
        ] {
            let encoded = try parameter(.text(value), type: BigQueryParameterType(type: type))
            #expect(encoded.parameterValue == BigQueryParameterValue(value: value))
        }
    }

    @Test("Bytes are sent as base64")
    func bytesAsBase64() throws {
        let encoded = try parameter(.bytes(Data([0x00, 0xFF, 0x10])), type: BigQueryParameterType(type: "BYTES"))
        #expect(encoded.parameterValue == BigQueryParameterValue(value: "AP8Q"))
    }

    @Test("An ARRAY is built from its JSON text")
    func arrayFromJSON() throws {
        let type = BigQueryParameterType(type: "ARRAY", arrayType: BigQueryParameterType(type: "INT64"))
        let encoded = try encodedJSON(parameter("[1, 2, 3]", type: type))
        let expected = #"{"name":"p1","parameterType":{"arrayType":{"type":"INT64"},"type":"ARRAY"},"#
            + #""parameterValue":{"arrayValues":[{"value":"1"},{"value":"2"},{"value":"3"}]}}"#
        #expect(encoded == expected)
    }

    @Test("A boolean inside an array stays a boolean, not a number")
    func arrayOfBooleans() throws {
        let type = BigQueryParameterType(type: "ARRAY", arrayType: BigQueryParameterType(type: "BOOL"))
        let encoded = try parameter("[true, false]", type: type)
        #expect(encoded.parameterValue?.arrayValues?.map(\.value) == ["true", "false"])
    }

    @Test("A STRUCT is built from its JSON object by field name")
    func structFromJSON() throws {
        let type = BigQueryParameterType(
            type: "STRUCT",
            structTypes: [
                BigQueryStructFieldType(name: "x", type: BigQueryParameterType(type: "INT64")),
                BigQueryStructFieldType(name: "y", type: BigQueryParameterType(type: "STRING"))
            ]
        )
        let encoded = try parameter(#"{"x": 1, "y": "foo"}"#, type: type)
        #expect(encoded.parameterValue?.structValues?["x"] == BigQueryParameterValue(value: "1"))
        #expect(encoded.parameterValue?.structValues?["y"] == BigQueryParameterValue(value: "foo"))
    }

    @Test("A RANGE is built from its bracketed text with unbounded ends left out")
    func rangeFromText() throws {
        let type = BigQueryParameterType(type: "RANGE", rangeElementType: BigQueryParameterType(type: "DATE"))
        let encoded = try parameter("[2020-01-01, UNBOUNDED)", type: type)
        #expect(encoded.parameterValue?.rangeValue?.start == BigQueryParameterValue(value: "2020-01-01"))
        #expect(encoded.parameterValue?.rangeValue?.end == nil)
    }

    @Test("A parameter the dry run did not type is sent as STRING")
    func untypedFallsBackToString() throws {
        let encoded = try parameter("abc", type: nil)
        #expect(encoded.parameterType == BigQueryParameterType(type: "STRING"))
    }

    @Test("ARRAY text that is not a JSON array is refused")
    func invalidArrayThrows() {
        let type = BigQueryParameterType(type: "ARRAY", arrayType: BigQueryParameterType(type: "STRING"))
        #expect(throws: BigQueryParameterEncodingError.notJSONArray(position: 1)) {
            _ = try parameter("not json", type: type)
        }
    }

    @Test("Binary data bound to a text parameter must be UTF-8")
    func binaryForTextThrows() {
        #expect(throws: BigQueryParameterEncodingError.notText(position: 1)) {
            _ = try parameter(.bytes(Data([0xFF, 0xFE])), type: BigQueryParameterType(type: "STRING"))
        }
    }
}

@Suite("BigQuery dry run parameter discovery")
struct BigQueryDryRunDiscoveryTests {
    private static let dryRunResponse = """
        {
          "kind": "bigquery#job",
          "status": {"state": "DONE"},
          "statistics": {
            "totalBytesProcessed": "0",
            "query": {
              "statementType": "UPDATE",
              "totalBytesProcessed": "0",
              "undeclaredQueryParameters": [
                {"name": "p1", "parameterType": {"type": "STRING"}},
                {"name": "P2", "parameterType": {"type": "ARRAY", "arrayType": {"type": "INT64"}}},
                {"name": "p3", "parameterType": {"type": "STRUCT", "structTypes": [
                  {"name": "a", "type": {"type": "BOOL"}, "description": "ignored"}
                ]}}
              ]
            }
          }
        }
        """

    @Test("The undeclared parameters of a dry run decode into types by name")
    func decodesUndeclaredParameters() throws {
        let job = try JSONDecoder().decode(BQJobResponse.self, from: Data(Self.dryRunResponse.utf8))
        let types = BigQueryQueryParameters.discoveredTypes(from: job.statistics?.query?.undeclaredQueryParameters)
        #expect(types["p1"] == BigQueryParameterType(type: "STRING"))
        #expect(types["p2"] == BigQueryParameterType(type: "ARRAY", arrayType: BigQueryParameterType(type: "INT64")))
        #expect(types["p3"]?.structTypes?.first?.name == "a")
        #expect(types["p3"]?.structTypes?.first?.type == BigQueryParameterType(type: "BOOL"))
    }

    @Test("A dry run request asks for named parameters and sends none")
    func dryRunRequestShape() throws {
        let request = BQJobRequest(
            jobReference: nil,
            configuration: BQJobRequest.BQJobConfiguration(
                query: BQJobRequest.BQQueryConfig(
                    query: "SELECT @p1",
                    useLegacySql: false,
                    defaultDataset: nil,
                    maximumBytesBilled: nil,
                    parameterMode: "NAMED",
                    queryParameters: nil
                ),
                dryRun: true,
                jobTimeoutMs: nil
            )
        )
        let encoded = try encodedJSON(request)
        let expected = #"{"configuration":{"dryRun":true,"query":{"parameterMode":"NAMED","#
            + #""query":"SELECT @p1","useLegacySql":false}}}"#
        #expect(encoded == expected)
    }

    @Test("The parameter memo is dropped on eviction")
    func memoEviction() {
        let cache = BigQueryParameterTypeCache()
        cache.store(["p1": BigQueryParameterType(type: "INT64")], for: "k")
        #expect(cache.types(for: "k")?["p1"] == BigQueryParameterType(type: "INT64"))
        cache.evict("k")
        #expect(cache.types(for: "k") == nil)
    }
}

@Suite("BigQuery job polling")
struct BigQueryJobPollingTests {
    @Test("A query timeout of zero sets no deadline and no job timeout")
    func zeroMeansNoLimit() {
        #expect(BigQueryJobPolling.deadline(queryTimeoutSeconds: 0, from: Date()) == nil)
        #expect(BigQueryJobPolling.jobTimeoutMilliseconds(queryTimeoutSeconds: 0) == nil)
    }

    @Test("A positive timeout passes straight through without a floor")
    func positiveTimeoutPassesThrough() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(BigQueryJobPolling.jobTimeoutMilliseconds(queryTimeoutSeconds: 5) == "5000")
        let deadline = BigQueryJobPolling.deadline(queryTimeoutSeconds: 5, from: start)
        #expect(deadline == start.addingTimeInterval(TimeInterval(5 + BigQueryJobPolling.deadlineGraceSeconds)))
    }
}
