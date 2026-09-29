import Foundation
import TableProPluginKit
import XCTest

final class HanaBridgeContractTests: XCTestCase {
    func testQueryEnvelopeDecodesTextNullAndBytesCells() throws {
        let json = """
            {"columns":["ID","NAME","PAYLOAD"],"columnTypeNames":["INTEGER","NVARCHAR","VARBINARY"],
             "columnClassifications":[null,null,null],
             "rows":[["1","a",{"bytes":"AAEC/w=="}],["2",null,null]],
             "rowsAffected":0,"hasResultSet":true,"executionTime":0.0123,"isTruncated":false,"truncatedLobCount":0}
            """
        let envelope = try decode(json)

        XCTAssertEqual(envelope.columns, ["ID", "NAME", "PAYLOAD"])
        XCTAssertEqual(envelope.rows[0], [.text("1"), .text("a"), .bytes(Data([0, 1, 2, 255]))])
        XCTAssertEqual(envelope.rows[1], [.text("2"), .null, .null])

        let result = HanaResultMapping.pluginResult(from: envelope)
        XCTAssertEqual(result.columnTypeNames, ["INTEGER", "NVARCHAR", "VARBINARY"])
        XCTAssertEqual(result.rows[0], [.text("1"), .text("a"), .bytes(Data([0, 1, 2, 255]))])
        XCTAssertEqual(result.rows[1], [.text("2"), .null, .null])
        XCTAssertEqual(result.executionTime, 0.0123, accuracy: 1e-6)
        XCTAssertNil(result.columnMeta)
        XCTAssertNil(result.statusMessage)
    }

    func testDataManipulationEnvelopeCarriesRowsAffectedAndNoRows() throws {
        let json = """
            {"columns":[],"columnTypeNames":[],"columnClassifications":[],"rows":[],
             "rowsAffected":42,"hasResultSet":false,"executionTime":0.5,"isTruncated":false,"truncatedLobCount":0}
            """
        let result = HanaResultMapping.pluginResult(from: try decode(json))

        XCTAssertEqual(result.rowsAffected, 42)
        XCTAssertTrue(result.columns.isEmpty)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertFalse(result.isTruncated)
    }

    func testEmptyResultSetKeepsItsColumns() throws {
        let json = """
            {"columns":["ID"],"columnTypeNames":["BIGINT"],"columnClassifications":[null],"rows":[],
             "rowsAffected":0,"hasResultSet":true,"executionTime":0,"isTruncated":false,"truncatedLobCount":0}
            """
        let result = HanaResultMapping.pluginResult(from: try decode(json))

        XCTAssertEqual(result.columns, ["ID"])
        XCTAssertEqual(result.columnTypeNames, ["BIGINT"])
        XCTAssertTrue(result.rows.isEmpty)
    }

    func testSessionLostIsReadAndDefaultsToFalse() throws {
        let fields = """
            "columns":[],"columnTypeNames":[],"columnClassifications":[],"rows":[],
            "rowsAffected":1,"hasResultSet":false,"executionTime":0,"isTruncated":false,"truncatedLobCount":0
            """

        XCTAssertTrue(try decode("{\(fields),\"sessionLost\":true}").sessionLost)
        XCTAssertFalse(try decode("{\(fields),\"sessionLost\":false}").sessionLost)
        XCTAssertFalse(try decode("{\(fields)}").sessionLost)
    }

    func testNumericCellsAreRejectedBecauseTheContractSendsText() {
        let json = """
            {"columns":["ID"],"columnTypeNames":["INTEGER"],"columnClassifications":[null],"rows":[[1]],
             "rowsAffected":0,"hasResultSet":true,"executionTime":0,"isTruncated":false,"truncatedLobCount":0}
            """
        XCTAssertThrowsError(try decode(json))
    }

    func testInvalidBase64BytesAreRejected() {
        let json = """
            {"columns":["B"],"columnTypeNames":["BLOB"],"columnClassifications":[null],"rows":[[{"bytes":"%%%"}]],
             "rowsAffected":0,"hasResultSet":true,"executionTime":0,"isTruncated":false,"truncatedLobCount":0}
            """
        XCTAssertThrowsError(try decode(json))
    }

    func testClassificationHintsBecomeColumnMeta() throws {
        let json = """
            {"columns":["CREATED","AMOUNT","NAME"],"columnTypeNames":["SECONDDATE","SMALLDECIMAL","NVARCHAR"],
             "columnClassifications":["TIMESTAMP","DECIMAL",null],"rows":[],
             "rowsAffected":0,"hasResultSet":true,"executionTime":0,"isTruncated":false,"truncatedLobCount":0}
            """
        let result = HanaResultMapping.pluginResult(from: try decode(json))
        let meta = try XCTUnwrap(result.columnMeta)

        XCTAssertEqual(meta.map(\.name), ["CREATED", "AMOUNT", "NAME"])
        XCTAssertEqual(meta.map(\.dataType), ["SECONDDATE", "SMALLDECIMAL", "NVARCHAR"])
        XCTAssertEqual(meta.map(\.classificationTypeName), ["TIMESTAMP", "DECIMAL", nil])
        XCTAssertEqual(result.columnTypeNames, ["SECONDDATE", "SMALLDECIMAL", "NVARCHAR"])
    }

    func testMismatchedClassificationCountIsIgnored() {
        let envelope = HanaResultEnvelope(
            columns: ["A", "B"],
            columnTypeNames: ["SECONDDATE", "INTEGER"],
            columnClassifications: ["TIMESTAMP"],
            rows: [],
            rowsAffected: 0,
            hasResultSet: true,
            executionTime: 0,
            isTruncated: false,
            truncatedLobCount: 0
        )
        XCTAssertNil(HanaResultMapping.columnMeta(for: envelope))
    }

    func testTruncatedLobsAndRowCapAreReported() throws {
        let json = """
            {"columns":["DOC"],"columnTypeNames":["NCLOB"],"columnClassifications":[null],"rows":[["x"]],
             "rowsAffected":0,"hasResultSet":true,"executionTime":0,"isTruncated":true,"truncatedLobCount":3}
            """
        let result = HanaResultMapping.pluginResult(from: try decode(json))

        XCTAssertTrue(result.isTruncated)
        let message = try XCTUnwrap(result.statusMessage)
        XCTAssertTrue(message.contains("3"))
        XCTAssertNil(HanaResultMapping.statusMessage(truncatedLobCount: 0))
    }

    func testExecuteRequestEncodesAbsentParametersAsNull() throws {
        let request = HanaExecuteRequest(sql: "SELECT 1 FROM DUMMY", parameters: nil, rowCap: 1_000, timeoutSeconds: 30)
        let object = try jsonObject(request)

        XCTAssertEqual(object["sql"] as? String, "SELECT 1 FROM DUMMY")
        XCTAssertTrue(object["parameters"] is NSNull)
        XCTAssertEqual(object["rowCap"] as? Int, 1_000)
        XCTAssertEqual(object["timeoutSeconds"] as? Int, 30)
    }

    func testExecuteRequestEncodesEveryParameterKind() throws {
        let request = HanaExecuteRequest(
            sql: "UPDATE T SET A = ?, B = ?, C = ? WHERE ID = ?",
            parameters: [.text("it's"), .null, .bytes(Data([0xDE, 0xAD])), .text("7")],
            rowCap: 0,
            timeoutSeconds: 0
        )
        let object = try jsonObject(request)
        let parameters = try XCTUnwrap(object["parameters"] as? [Any])

        XCTAssertEqual(parameters[0] as? String, "it's")
        XCTAssertTrue(parameters[1] is NSNull)
        XCTAssertEqual((parameters[2] as? [String: String])?["bytes"], "3q0=")
        XCTAssertEqual(parameters[3] as? String, "7")
    }

    func testBridgeCellsRoundTripPluginValues() {
        let values: [PluginCellValue] = [.null, .text("x"), .bytes(Data([1, 2]))]
        XCTAssertEqual(values.map { HanaBridgeCell($0).pluginValue }, values)
    }

    func testConnectConfigurationUsesTheContractSpelling() throws {
        let configuration = HanaConnectConfiguration(
            host: "abc.hana.prod-eu10.hanacloud.ondemand.com",
            port: 443,
            username: "DBADMIN",
            password: "secret",
            schema: "APP",
            tlsMode: .verifyIdentity,
            tlsServerName: "",
            caCertificatePath: "",
            clientCertificatePath: "",
            clientKeyPath: "",
            connectTimeoutSeconds: 30
        )
        let object = try jsonObject(configuration)

        XCTAssertEqual(object["tlsMode"] as? String, "verifyIdentity")
        XCTAssertEqual(object["port"] as? Int, 443)
        XCTAssertEqual(object["connectTimeoutSeconds"] as? Int, 30)
        XCTAssertEqual(
            Set(object.keys),
            [
                "host", "port", "username", "password", "schema", "tlsMode", "tlsServerName",
                "caCertificatePath", "clientCertificatePath", "clientKeyPath", "connectTimeoutSeconds"
            ]
        )
        XCTAssertEqual(HanaConnectConfiguration.TLSMode(.verifyCa).rawValue, "verifyCa")
        XCTAssertEqual(HanaConnectConfiguration.TLSMode(.preferred).rawValue, "preferred")
        XCTAssertEqual(HanaConnectConfiguration.TLSMode(.required).rawValue, "required")
        XCTAssertEqual(HanaConnectConfiguration.TLSMode(.disabled).rawValue, "disabled")
    }

    func testExplainRequestCarriesTheInnerStatement() throws {
        let object = try jsonObject(HanaExplainRequest(sql: "SELECT * FROM T", timeoutSeconds: 5))

        XCTAssertEqual(object["sql"] as? String, "SELECT * FROM T")
        XCTAssertEqual(object["timeoutSeconds"] as? Int, 5)
    }

    func testConnectResultDecodes() throws {
        let json = #"{"serverVersion":"2.00.070.00.1234567890","currentSchema":"APP","connectionId":200123}"#
        let result = try JSONDecoder().decode(HanaConnectResult.self, from: Data(json.utf8))

        XCTAssertEqual(
            result,
            HanaConnectResult(serverVersion: "2.00.070.00.1234567890", currentSchema: "APP", connectionId: 200_123)
        )
    }

    func testFailureDecodesEveryField() {
        let json = """
            {"kind":"parameter","code":0,"position":0,"message":"2024-13-01","parameter":2,"expected":"date"}
            """
        let failure = HanaBridgeFailure.decoded(from: Data(json.utf8))

        XCTAssertEqual(
            failure,
            HanaBridgeFailure(kind: .parameter, message: "2024-13-01", parameter: 2, expected: "date")
        )
    }

    func testFailureKindsMatchTheContract() {
        let kinds = [
            "server", "cancelled", "timeout", "connectionLost", "closed", "parameter", "tls",
            "configuration", "connect", "internal"
        ]
        let decoded = kinds.map { HanaBridgeFailure.decoded(from: Data(#"{"kind":"\#($0)"}"#.utf8)).kind }

        XCTAssertEqual(
            decoded,
            [
                .server, .cancelled, .timeout, .connectionLost, .closed, .parameter, .tls,
                .configuration, .connect, .internalFailure
            ]
        )
    }

    func testUnknownOrUnreadableFailureBecomesInternal() {
        let unknown = HanaBridgeFailure.decoded(from: Data(#"{"kind":"surprise","message":"m"}"#.utf8))
        XCTAssertEqual(unknown.kind, .internalFailure)
        XCTAssertEqual(unknown.message, "m")

        let unreadable = HanaBridgeFailure.decoded(from: Data("not json".utf8))
        XCTAssertEqual(unreadable.kind, .internalFailure)
        XCTAssertEqual(unreadable.message, "not json")
    }

    private func decode(_ json: String) throws -> HanaResultEnvelope {
        try JSONDecoder().decode(HanaResultEnvelope.self, from: Data(json.utf8))
    }

    private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
