import Foundation
import TableProTrinoCore
import Testing

private final class RecordingTransport: TrinoTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TrinoHTTPRequest] = []
    private let responseHeaders: [String: String]

    init(responseHeaders: [String: String] = [:]) {
        self.responseHeaders = responseHeaders
    }

    var requests: [TrinoHTTPRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: TrinoHTTPRequest) async throws -> TrinoHTTPResponse {
        lock.withLock { recorded.append(request) }
        let body = #"{"id":"q1","columns":[{"name":"x","type":"integer"}],"data":[[1]]}"#
        return TrinoHTTPResponse(statusCode: 200, headers: TrinoHeaderFields(responseHeaders), body: Data(body.utf8))
    }

    func cancelAll() {}
}

struct TrinoServerFlavorTests {
    private func config(_ flavor: TrinoServerFlavor) -> TrinoClientConfig {
        TrinoClientConfig(host: "localhost", user: "analyst", catalog: "hive", schema: "web", flavor: flavor)
    }

    private func firstRequest(_ flavor: TrinoServerFlavor) async throws -> TrinoHTTPRequest {
        let transport = RecordingTransport()
        let session = TrinoSessionState(catalog: "hive", schema: "web")
        let client = TrinoStatementClient(transport: transport, config: config(flavor), session: session)
        _ = try await client.execute("SELECT 1")
        return try #require(transport.requests.first)
    }

    @Test("The driver variant picks the flavor, and anything but Presto stays Trino")
    func flavorFromDriverVariant() {
        #expect(TrinoServerFlavor(driverVariant: "Presto") == .presto)
        #expect(TrinoServerFlavor(driverVariant: "Trino") == .trino)
        #expect(TrinoServerFlavor(driverVariant: nil) == .trino)
        #expect(TrinoServerFlavor(driverVariant: "presto") == .trino)
    }

    @Test("A Presto statement names its user, catalog and schema under X-Presto-")
    func prestoSendsPrestoHeaders() async throws {
        let headers = try await firstRequest(.presto).headers
        #expect(headers["X-Presto-User"] == "analyst")
        #expect(headers["X-Presto-Source"] == "TablePro")
        #expect(headers["X-Presto-Catalog"] == "hive")
        #expect(headers["X-Presto-Schema"] == "web")
        #expect(!headers.keys.contains { $0.hasPrefix("X-Trino-") })
    }

    @Test("Presto gets no client capabilities header, which it does not define")
    func prestoSendsNoCapabilities() async throws {
        let headers = try await firstRequest(.presto).headers
        #expect(!headers.keys.contains { $0.hasSuffix("Client-Capabilities") })
    }

    @Test("Trino still asks for parametric datetimes")
    func trinoSendsCapabilities() async throws {
        let headers = try await firstRequest(.trino).headers
        #expect(headers["X-Trino-User"] == "analyst")
        #expect(headers["X-Trino-Client-Capabilities"] == "PARAMETRIC_DATETIME")
    }

    @Test("A Presto client follows X-Presto-Set-Schema and ignores the Trino spelling")
    func prestoReadsPrestoResponseHeaders() async throws {
        let transport = RecordingTransport(responseHeaders: [
            "X-Presto-Set-Schema": "events",
            "X-Trino-Set-Catalog": "other",
        ])
        let session = TrinoSessionState(catalog: "hive", schema: "web")
        let client = TrinoStatementClient(transport: transport, config: config(.presto), session: session)
        _ = try await client.execute("USE events")
        #expect(session.schema == "events")
        #expect(session.catalog == "hive")
    }

    @Test("Presto connects on SELECT 1 and reads its version from the coordinator node, having no version()")
    func prestoConnectAndVersionStatements() {
        #expect(TrinoServerFlavor.presto.connectStatement == "SELECT 1")
        #expect(TrinoServerFlavor.presto.versionStatement.contains("system.runtime.nodes"))
        #expect(TrinoServerFlavor.trino.connectStatement == "SELECT version()")
        #expect(TrinoServerFlavor.trino.versionStatement == TrinoServerFlavor.trino.connectStatement)
    }

    @Test("Presto reads materialized views from information_schema and has no table comment query")
    func prestoIntrospection() {
        let views = TrinoIntrospectionSQL.listMaterializedViews(catalog: "hive", schema: "web", flavor: .presto)
        #expect(views.contains(#"FROM "hive".information_schema.materialized_views"#))
        #expect(views.contains("table_schema = 'web'"))
        #expect(!views.contains("system.metadata"))

        let one = TrinoIntrospectionSQL.materializedView(catalog: "hive", schema: "web", name: "mv", flavor: .presto)
        #expect(one.hasSuffix("AND table_name = 'mv'"))

        #expect(TrinoIntrospectionSQL.tableComment(catalog: "hive", schema: "web", table: "t", flavor: .presto) == nil)
    }

    @Test("Trino keeps reading system.metadata")
    func trinoIntrospection() {
        let views = TrinoIntrospectionSQL.listMaterializedViews(catalog: "hive", schema: "web", flavor: .trino)
        #expect(views.contains("system.metadata.materialized_views"))
        let one = TrinoIntrospectionSQL.materializedView(catalog: "hive", schema: "web", name: "mv", flavor: .trino)
        #expect(one.hasSuffix("AND name = 'mv'"))
        let comment = TrinoIntrospectionSQL.tableComment(catalog: "hive", schema: "web", table: "t", flavor: .trino)
        #expect(comment?.contains("system.metadata.table_comments") == true)
    }

    @Test("An array, map or row sent as JSON text reads the same as one sent as JSON")
    func structuredValueSentAsText() {
        let asText = TrinoValueDecoder.decode(.string("[ 1, 2 ]"), category: .structured)
        let asJSON = TrinoValueDecoder.decode(.array([.int(1), .int(2)]), category: .structured)
        #expect(asText == .text("[1,2]"))
        #expect(asText == asJSON)
        #expect(TrinoValueDecoder.decode(.string(#"{ "k" : 1 }"#), category: .structured) == .text(#"{"k":1}"#))
    }

    @Test("Presto's sketch types arrive as base64 binary", arguments: ["KHyperLogLog", "kllsketch(bigint)"])
    func prestoSketchTypesAreBinary(type: String) {
        #expect(TrinoTypeMapper.category(forRawType: type) == .binary)
    }
}
