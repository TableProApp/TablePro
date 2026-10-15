import Foundation
@testable import TableProBigtableCore
import TableProGoogleCloud
import Testing

struct BigtableConnectionSettingsTests {
    @Test("Settings take the project from the credential and refuse IDs that would change the path")
    func settings() throws {
        let parsed = try BigtableConnectionSettings.parse(fields: ["btInstanceId": "ea-bt-01"], credentialProject: "my-proj")
        #expect(parsed == BigtableConnectionSettings(projectId: "my-proj", instanceId: "ea-bt-01"))
        #expect(throws: BigtableError.self) { try BigtableConnectionSettings.parse(fields: [:]) }
        #expect(throws: BigtableError.self) { try BigtableConnectionSettings.parse(fields: ["btProjectId": "p-123", "btInstanceId": "../x"]) }
        #expect(throws: BigtableError.self) { try BigtableConnectionSettings.parse(fields: ["btProjectId": "Bad Project"]) }
        #expect(throws: BigtableError.self) { try BigtableConnectionSettings.parse(fields: ["btProjectId": "p-123"], database: "a/b") }
    }

    @Test("The database a connection opens on names its instance ahead of the Instance ID field")
    func databaseNamesTheInstance() throws {
        let fields = ["btProjectId": "my-proj", "btInstanceId": "first"]
        #expect(try BigtableConnectionSettings.parse(fields: fields, database: "second").instanceId == "second")
        #expect(try BigtableConnectionSettings.parse(fields: fields, database: " ").instanceId == "first")
        #expect(try BigtableConnectionSettings.parse(fields: ["btProjectId": "my-proj"]).instanceId == nil)
    }

    @Test("The credential comes from the key field, the password, or Application Default Credentials")
    func credentialSource() throws {
        #expect(try BigtableConnectionSettings.credentialSource(fields: ["btServiceAccountJson": "/k.json"], password: nil) == .serviceAccountKey("/k.json"))
        #expect(try BigtableConnectionSettings.credentialSource(fields: [:], password: " {} ") == .serviceAccountKey("{}"))
        #expect(try BigtableConnectionSettings.credentialSource(fields: ["btAuthMethod": "adc"], password: nil) == .applicationDefault)
        #expect(throws: BigtableError.self) { try BigtableConnectionSettings.credentialSource(fields: [:], password: "") }
    }

    /// `PluginMetadataRegistry+BigtableDefaults.swift` in the app spells these IDs out, since the app
    /// links no engine core. Renaming one here strands the connections saved under the old one.
    @Test("Field IDs keep the spelling saved connections and the app's defaults use")
    func fieldIDs() {
        #expect([
            BigtableFieldID.authMethod, BigtableFieldID.serviceAccountJson, BigtableFieldID.projectId,
            BigtableFieldID.instanceId, BigtableFieldID.appProfileId
        ] == ["btAuthMethod", "btServiceAccountJson", "btProjectId", "btInstanceId", "btAppProfileId"])
        #expect(BigtableAuthMethod.applicationDefault.rawValue == "adc")
    }
}

struct BigtableClientTests {
    private static let committedRow = """
    [{"chunks": [{"rowKey": "\(b64("k"))", "familyName": "cf", "qualifier": "\(b64("a"))", "timestampMicros": "1", "value": "", "commitRow": true}]}]
    """

    private func client(_ transport: RecordingTransport) -> BigtableClient {
        BigtableClient(
            projectId: "proj", instanceId: "inst", transport: transport,
            credential: GoogleRESTCredential(token: { "token" }), timeout: { 30 }
        )
    }

    private static func reply(_ body: String, status: Int = 200) -> GoogleRESTResponse {
        GoogleRESTResponse(statusCode: status, body: Data(body.utf8))
    }

    @Test("An insert onto a key that already has a row is refused without writing")
    func insertRefusesExistingKey() async throws {
        let transport = RecordingTransport { _ in Self.reply(Self.committedRow) }
        let column = BigtableColumn(family: "cf", qualifier: Data("a".utf8))

        await #expect(throws: BigtableError.self) {
            try await client(transport).insertRow(table: "t", key: Data("k".utf8), mutations: [.setCell(column, Data("1".utf8))])
        }
        #expect(transport.requests.map { $0.path } == ["/v2/projects/proj/instances/inst/tables/t:readRows"])
    }

    @Test("An insert onto a free key looks it up, then writes the row")
    func insertWritesFreeKey() async throws {
        let transport = RecordingTransport { request in
            Self.reply(request.path.hasSuffix(":readRows") ? "[]" : "{}")
        }
        let column = BigtableColumn(family: "cf", qualifier: Data("a".utf8))

        try await client(transport).insertRow(table: "t", key: Data("k".utf8), mutations: [.setCell(column, Data("1".utf8))])

        let requests = transport.requests
        #expect(requests.map { $0.path } == [
            "/v2/projects/proj/instances/inst/tables/t:readRows",
            "/v2/projects/proj/instances/inst/tables/t:mutateRow"
        ])
        #expect(jsonText(requests[0].jsonBody["rows"] ?? [:]) == #"{"rowKeys":["\#(b64("k"))"]}"#)
        #expect(requests[1].jsonBody["rowKey"] as? String == b64("k"))
    }

    @Test("A read the filters ruled out sends no request")
    func emptyReadSendsNothing() async throws {
        let transport = RecordingTransport { _ in Self.reply("[]") }
        #expect(try await client(transport).readRows(table: "t", body: nil).isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test("A health check asks for one table name, not every page of them")
    func pingReadsOnePage() async throws {
        let transport = RecordingTransport { _ in Self.reply(#"{"tables": [{"name": "x/tables/a"}], "nextPageToken": "more"}"#) }
        try await client(transport).ping()
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageSize" }?.value == "1")
    }

    @Test("A denied read is a permission error naming the table, not an empty page")
    func deniedRead() async {
        let transport = RecordingTransport { _ in Self.reply(#"[{"error": {"code": 403, "message": "bigtable.tables.readRows denied"}}]"#, status: 403) }
        await #expect(throws: BigtableError.permissionDenied(operation: "read t", detail: "bigtable.tables.readRows denied")) {
            try await client(transport).readRows(table: "t", body: [:])
        }
    }
}
