import Foundation
import Testing

@testable import TableProSpannerCore

@Suite("Spanner wire decoding")
struct SpannerWireDecodingTests {
    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func encodedObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("The emulator's typed result decodes, including a field with no name")
    func emulatorResultSet() throws {
        let json = """
        {"metadata":{"rowType":{"fields":[{"type":{"code":"INT64"}},{"name":"arr","type":{"code":"ARRAY",\
        "arrayElementType":{"code":"STRUCT","structType":{"fields":[{"name":"x","type":{"code":"INT64"}},\
        {"name":"y","type":{"code":"STRING"}}]}}}},{"name":"j","type":{"code":"JSON","typeAnnotation":"PG_JSONB"}}]}},\
        "rows":[["1",[["1","y"]],"{\\"a\\":1}"]]}
        """
        let result = try decode(SpannerResultSet.self, json)
        let fields = try #require(result.metadata?.fields)
        #expect(fields.count == 3)
        #expect(fields[0].name == "")
        #expect(fields[0].type.code == "INT64")
        let element = try #require(fields[1].type.arrayElementType)
        #expect(element.code == "STRUCT")
        #expect(element.structFields.map(\.name) == ["x", "y"])
        #expect(fields[2].type.typeAnnotation == "PG_JSONB")
        #expect(result.rows == [[.string("1"), .list([.list([.string("1"), .string("y")])]), .string(#"{"a":1}"#)]])
        #expect(result.stats == nil)
    }

    @Test("A result with no rows key has no rows")
    func missingRows() throws {
        let result = try decode(SpannerResultSet.self, #"{"metadata":{"rowType":{"fields":[]}}}"#)
        #expect(result.rows.isEmpty)
        #expect(result.metadata?.fields.isEmpty == true)
    }

    @Test("DML stats carry int64 counts as strings and the begun transaction id")
    func dmlStats() throws {
        let json = """
        {"metadata":{"rowType":{},"transaction":{"id":"MTc4OQ=="}},"stats":{"rowCountExact":"3"}}
        """
        let result = try decode(SpannerResultSet.self, json)
        #expect(result.metadata?.transactionId == "MTc4OQ==")
        #expect(result.stats?.rowCountExact == 3)
        #expect(result.stats?.rowCountLowerBound == nil)
    }

    @Test("Row counts also decode from JSON numbers")
    func numericCounts() throws {
        let stats = try decode(SpannerResultSetStats.self, #"{"rowCountLowerBound":7}"#)
        #expect(stats.rowCountLowerBound == 7)
    }

    @Test("Undeclared parameters from a PLAN request decode")
    func undeclaredParameters() throws {
        let json = """
        {"metadata":{"rowType":{"fields":[{"name":"x","type":{"code":"INT64"}}]},\
        "undeclaredParameters":{"fields":[{"name":"p1","type":{"code":"INT64"}}]}},\
        "stats":{"queryPlan":{"planNodes":[{"displayName":"No query plan"}]}}}
        """
        let result = try decode(SpannerResultSet.self, json)
        #expect(result.metadata?.undeclaredParameters == [SpannerField(name: "p1", type: SpannerType(code: "INT64"))])
        let nodes = try #require(result.stats?.queryPlan?.nodes)
        #expect(nodes == [SpannerPlanNode(index: 0, displayName: "No query plan")])
    }

    @Test("Plan nodes decode child links, short representations and metadata")
    func planNodes() throws {
        let json = """
        {"planNodes":[{"kind":"RELATIONAL","displayName":"Distributed Union","childLinks":[{"childIndex":1},\
        {"childIndex":"2","type":"Split Range"}],"metadata":{"subquery_cluster_node":"1"}},\
        {"index":1,"kind":"RELATIONAL","displayName":"Scan","childLinks":[]},\
        {"index":2,"kind":"SCALAR","displayName":"Function","shortRepresentation":{"description":"($x > 1)"}}]}
        """
        let plan = try decode(SpannerQueryPlan.self, json)
        #expect(plan.nodes.count == 3)
        #expect(plan.nodes[0].index == 0)
        #expect(plan.nodes[0].childLinks == [
            SpannerPlanNode.ChildLink(childIndex: 1),
            SpannerPlanNode.ChildLink(childIndex: 2, type: "Split Range")
        ])
        #expect(plan.nodes[0].metadata == ["subquery_cluster_node": .string("1")])
        #expect(plan.nodes[2].shortDescription == "($x > 1)")
        #expect(plan.nodes[2].kind == "SCALAR")
    }

    @Test("A partial result set defaults its optional parts")
    func partialDefaults() throws {
        let partial = try decode(SpannerPartialResultSet.self, #"{"values":["1",null,true,1.5]}"#)
        #expect(partial.values == [.string("1"), .null, .bool(true), .number(1.5)])
        #expect(partial.chunkedValue == false)
        #expect(partial.metadata == nil)
        #expect(partial.resumeToken == nil)
    }

    @Test("The Foundation decoding path the client uses agrees with the Codable path")
    func foundationPathParity() throws {
        let resultJSON = """
        {"metadata":{"rowType":{"fields":[{"name":"a","type":{"code":"STRING"}}]},"transaction":{"id":"T"}},\
        "rows":[["1",true,false,0,1,1.5,1e+300,-0.25,null,"NaN",["a",["b"],{"k":"v"}],{"x":[1,"2"]}]],\
        "stats":{"rowCountExact":"12"}}
        """
        let codable = try decode(SpannerResultSet.self, resultJSON)
        let foundation = try SpannerResultSet(foundationObject: SpannerFoundationJSON.object(Data(resultJSON.utf8)))
        #expect(foundation == codable)
        #expect(foundation.rows.first?[1] == .bool(true))
        #expect(foundation.rows.first?[3] == .number(0))

        let partialJSON = #"{"values":["a",1,true,[null]],"chunkedValue":true,"resumeToken":"cmVz"}"#
        let partialCodable = try decode(SpannerPartialResultSet.self, partialJSON)
        let partialFoundation = try SpannerPartialResultSet(
            foundationObject: SpannerFoundationJSON.object(Data(partialJSON.utf8))
        )
        #expect(partialFoundation == partialCodable)
        #expect(partialFoundation.chunkedValue)
        #expect(partialFoundation.resumeToken == "cmVz")
    }

    @Test("A result whose rows are not a list is an invalid response")
    func rowsNotAList() {
        #expect(throws: SpannerTransportError.invalidResponse) {
            try SpannerResultSet(foundationObject: SpannerFoundationJSON.object(Data(#"{"rows":{"a":1}}"#.utf8)))
        }
    }

    @Test("A JSON value keeps strings, booleans, numbers, lists and objects apart")
    func jsonValueRoundTrip() throws {
        let value = try decode(SpannerJSONValue.self, #"{"a":[1,"1",true,null,{"b":"c"}]}"#)
        #expect(value == .object(["a": .list([.number(1), .string("1"), .bool(true), .null, .object(["b": .string("c")])])]))
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(SpannerJSONValue.self, from: data) == value)
    }

    @Test("A recursive type encodes element, struct fields and annotation")
    func typeEncoding() throws {
        let type = SpannerType(
            code: "ARRAY",
            arrayElementType: SpannerType(
                code: "STRUCT",
                structFields: [SpannerField(name: "n", type: SpannerType(code: "NUMERIC", typeAnnotation: "PG_NUMERIC"))]
            )
        )
        let object = try encodedObject(type)
        #expect(object["code"] as? String == "ARRAY")
        #expect(object["structType"] == nil)
        let element = try #require(object["arrayElementType"] as? [String: Any])
        let structType = try #require(element["structType"] as? [String: Any])
        let fields = try #require(structType["fields"] as? [[String: Any]])
        #expect(fields.first?["name"] as? String == "n")
        let fieldType = try #require(fields.first?["type"] as? [String: Any])
        #expect(fieldType["typeAnnotation"] as? String == "PG_NUMERIC")
        let decoded = try JSONDecoder().decode(SpannerType.self, from: JSONEncoder().encode(type))
        #expect(decoded == type)
    }

    @Test("A single-use strong read encodes its selector and leaves params out when empty")
    func singleUseRequest() throws {
        let object = try encodedObject(SpannerExecuteSqlRequest(sql: "SELECT 1", transaction: .singleUseStrongReadOnly))
        #expect(object["sql"] as? String == "SELECT 1")
        let transaction = try #require(object["transaction"] as? [String: Any])
        let singleUse = try #require(transaction["singleUse"] as? [String: Any])
        let readOnly = try #require(singleUse["readOnly"] as? [String: Any])
        #expect(readOnly["strong"] as? Bool == true)
        #expect(object["params"] == nil)
        #expect(object["paramTypes"] == nil)
        #expect(object["seqno"] == nil)
        #expect(object["queryMode"] as? String == "NORMAL")
    }

    @Test("An inline begin encodes a read-write option and the seqno as a JSON string")
    func beginRequest() throws {
        let request = SpannerExecuteSqlRequest(
            sql: "DELETE FROM t WHERE TRUE",
            transaction: .beginReadWrite,
            queryMode: .plan,
            seqno: 1
        )
        let object = try encodedObject(request)
        let transaction = try #require(object["transaction"] as? [String: Any])
        let begin = try #require(transaction["begin"] as? [String: Any])
        #expect(begin["readWrite"] is [String: Any])
        #expect(object["seqno"] as? String == "1")
        #expect(object["queryMode"] as? String == "PLAN")
    }

    @Test("A transaction id selector carries params and their types")
    func idRequest() throws {
        let request = SpannerExecuteSqlRequest(
            sql: "UPDATE t SET a = @p1 WHERE k = @p2",
            transaction: .id("TXN"),
            params: ["p1": .bool(true), "p2": .string("9")],
            paramTypes: ["p1": SpannerType(code: "BOOL"), "p2": SpannerType(code: "INT64")],
            seqno: 42
        )
        let object = try encodedObject(request)
        let transaction = try #require(object["transaction"] as? [String: Any])
        #expect(transaction["id"] as? String == "TXN")
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["p1"] as? Bool == true)
        #expect(params["p2"] as? String == "9")
        let types = try #require(object["paramTypes"] as? [String: Any])
        #expect((types["p2"] as? [String: Any])?["code"] as? String == "INT64")
        #expect(object["seqno"] as? String == "42")
    }

    @Test("Replay safety follows the selector, the seqno and the query mode")
    func replaySafety() {
        #expect(SpannerExecuteSqlRequest(sql: "", transaction: .singleUseStrongReadOnly).isReplaySafe)
        #expect(SpannerExecuteSqlRequest(sql: "", transaction: .id("t"), seqno: 3).isReplaySafe)
        #expect(SpannerExecuteSqlRequest(sql: "", transaction: .beginReadWrite, queryMode: .plan).isReplaySafe)
        #expect(!SpannerExecuteSqlRequest(sql: "", transaction: .id("t")).isReplaySafe)
        #expect(!SpannerExecuteSqlRequest(sql: "", transaction: .beginReadWrite).isReplaySafe)
    }
}
