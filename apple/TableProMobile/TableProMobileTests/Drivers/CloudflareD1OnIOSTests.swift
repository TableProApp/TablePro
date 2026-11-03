import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

struct CloudflareD1OnIOSTests {
    private static let base = "/client/v4/accounts/acc123/d1/database"
    private static let appUUID = "8a1f3f6e-0c2d-4b7a-9e51-2f4c6d8b0a13"
    private static let archiveUUID = "5c9e2b71-3d4a-4f86-a0b2-7e1d9c3f5a64"

    // An account holding `app` and `archive`; every query answers `raw`.
    private func account(raw: String = D1Wire.rows([], "[]")) -> D1Stub.Script {
        D1Stub.Script { exchange in
            switch (exchange.method, exchange.path) {
            case ("GET", "\(Self.base)/app"), ("GET", "\(Self.base)/\(Self.appUUID)"):
                return D1Stub.Reply(body: D1Wire.database("app", uuid: Self.appUUID))
            case ("GET", "\(Self.base)/archive"), ("GET", "\(Self.base)/\(Self.archiveUUID)"):
                return D1Stub.Reply(body: D1Wire.database("archive", uuid: Self.archiveUUID))
            case ("POST", let path) where path.hasSuffix("/raw"):
                return D1Stub.Reply(body: raw)
            default:
                return D1Stub.Reply(status: 404, body: D1Wire.notFound)
            }
        }
    }

    private func plugin(
        database: String = "app",
        token: String = "token",
        accountId: String = "acc123",
        script: D1Stub.Script
    ) -> CloudflareD1PluginDriver {
        CloudflareD1PluginDriver(
            config: DriverConnectionConfig(
                host: "", port: 0, username: "", password: token, database: database,
                additionalFields: [CloudflareD1Plugin.accountIdFieldId: accountId]
            ),
            sessionConfiguration: script.configuration
        )
    }

    private func connection(database: String = "app") -> DatabaseConnection {
        DatabaseConnection(
            name: "Edge", type: .cloudflareD1, host: "", port: 0, database: database,
            additionalFields: [CloudflareD1Plugin.accountIdFieldId: "acc123"]
        )
    }

    private var connectContext: ErrorContext {
        ErrorContext(operation: "connect", databaseType: .cloudflareD1, host: "")
    }

    // MARK: - Factory

    // D1's plugin writes no rows of its own, so a row writer would fail every edit; an empty host would be probed for
    // Local Network permission.
    @Test("The factory opens D1 as a plain plugin driver, with no host to ask Local Network permission for")
    func factoryOpensD1() throws {
        let opened = try IOSDriverFactory().createDriver(for: connection(), password: "token")

        let driver = try #require(opened as? CloudflareD1BackedDriver)
        #expect(!(opened is any DriverRowWriting))
        #expect(driver.dialedHosts.isEmpty)
        #expect(driver.supportsTransactions == false)
        #expect(IOSDriverFactory.refusal(for: connection()) == nil)
        #expect(!IOSDriverFactory().opensCatalogConnections(for: connection()))
    }

    @Test("The factory hands the plugin the account, the token and the database the connection stores")
    func factoryCarriesTheConnection() async throws {
        let script = account()
        let factory = IOSDriverFactory(apiSessionConfiguration: { script.configuration })

        let driver = try factory.createDriver(for: connection(), password: "secret-token")
        try await driver.connect()

        let lookup = try #require(script.exchanges.first)
        #expect(lookup.method == "GET")
        #expect(lookup.path == "\(Self.base)/app")
        #expect(lookup.authorization == "Bearer secret-token")
        #expect(driver.currentDatabase == "app")
    }

    @Test("D1 is offered, opens here, takes rows from Shortcuts, and has no port")
    @MainActor
    func typeIsListed() {
        #expect(DatabaseType.mobileSupportedTypes.contains(.cloudflareD1))
        #expect(IOSDriverFactory.supportedTypeList.contains(.cloudflareD1))
        #expect(IntentDatabaseSession.supportsTabularInsert(.cloudflareD1))
        #expect(DatabaseType.cloudflareD1.mobileDisplayName == "Cloudflare D1")
        #expect(DatabaseType.cloudflareD1.defaultPort == "")
    }

    @Test("Each engine has the Mac's connection shape", arguments: [
        (DatabaseType.cloudflareD1, ConnectionMode.apiOnly),
        (.sqlite, .fileBased),
        (.duckdb, .fileBased),
        (.mysql, .network),
        (.clickhouse, .network)
    ])
    func connectionShape(type: DatabaseType, mode: ConnectionMode) {
        #expect(type.connectionMode == mode)
        #expect(type.isLocalFile == (mode == .fileBased))
    }

    // MARK: - Values

    // Before, every JSON shape but a number, a string or null read as NULL (measured), so a BLOB looked empty.
    @Test("Each value D1 sends keeps its value: bytes as bytes, a boolean as 1, any other JSON as its text")
    func valuesKeepTheirShape() async throws {
        let script = account(raw: D1Wire.rows(
            ["blob", "empty", "flag", "object", "big", "real", "text", "nothing"],
            #"[[[0,1,2,255],[],true,{"a":1},9007199254740993,2.5,"x",null]]"#
        ))
        let d1 = plugin(script: script)
        try await d1.connect()

        let result = try await d1.execute(query: "SELECT * FROM shapes")

        let expected: [[PluginCellValue]] = [[
            .bytes(Data([0, 1, 2, 255])), .bytes(Data()), "1", #"{"a":1}"#, "9007199254740993", "2.5", "x", .null
        ]]
        #expect(result.rows == expected)
    }

    @Test("A BLOB reaches the grid as a binary cell")
    func blobIsABinaryCell() async throws {
        let script = account(raw: D1Wire.rows(["id", "blob"], "[[1,[0,1,255]]]"))
        let driver = CloudflareD1BackedDriver(d1: plugin(script: script))
        try await driver.connect()

        var cells: [Cell] = []
        for try await element in driver.executeStreaming(query: "SELECT * FROM files", options: StreamOptions(maxRows: 10)) {
            if case .row(let row) = element { cells += row.cells }
        }

        guard cells.count == 2, case .binary(let count, _) = cells[1] else {
            Issue.record("the BLOB should arrive as a binary cell")
            return
        }
        #expect(count == 3)
    }

    // MARK: - Databases

    @Test("A connection that stores its database's UUID reports the database by name, after one lookup")
    func uuidConnectionReportsTheName() async throws {
        let script = account()
        let driver = CloudflareD1BackedDriver(d1: plugin(database: Self.appUUID, script: script))

        try await driver.connect()

        #expect(driver.currentDatabase == "app")
        #expect(script.exchanges.map { $0.path } == ["\(Self.base)/\(Self.appUUID)"])
    }

    // Behind PluginBackedDriver a stale name would make each catalog read switch back, so writes went to the old one.
    @Test("After a switch the driver reports the new database, and every later request goes to it")
    func switchMovesEveryRequest() async throws {
        let script = account()
        let driver = CloudflareD1BackedDriver(d1: plugin(script: script))
        try await driver.connect()

        try await driver.switchDatabase(to: "archive")
        _ = try await driver.fetchTables(schema: nil)
        _ = try await driver.execute(query: "SELECT 1")

        #expect(driver.currentDatabase == "archive")
        let queries = script.exchanges.filter { $0.method == "POST" }.map { $0.path }
        #expect(queries.count >= 2)
        #expect(queries.allSatisfy { $0 == "\(Self.base)/\(Self.archiveUUID)/raw" })
    }

    @Test("The account's databases are read page by page, until the count D1 reports")
    func listFollowsTheTotalCount() async throws {
        let script = D1Stub.Script { exchange in
            switch exchange.query["page"] ?? "" {
            case "1": return D1Stub.Reply(body: D1Wire.list(["a", "b"], total: 3))
            case "2": return D1Stub.Reply(body: D1Wire.list(["c"], total: 3))
            default: return D1Stub.Reply(body: D1Wire.list([], total: 3))
            }
        }

        let databases = try await CloudflareD1PluginDriver.listDatabases(
            accountId: "acc123", apiToken: "token", sessionConfiguration: script.configuration
        )

        #expect(databases.map { $0.name } == ["a", "b", "c"])
        #expect(script.exchanges.map { $0.query["page"] } == ["1", "2"])
        #expect(script.exchanges.allSatisfy { $0.query["per_page"] == "10000" })
    }

    @Test("A database the account does not hold is named in the error")
    func missingDatabaseIsNamed() async {
        let d1 = plugin(database: "missing", script: account())

        let thrown = await #expect(throws: (any Error).self) { try await d1.connect() }

        #expect(thrown?.localizedDescription
            == String(format: String(localized: "Database '%@' not found in account"), "missing"))
    }

    // MARK: - Errors

    @Test("A token D1 refuses keeps its own error and asks for the token and account, never a username")
    func refusedTokenIsAuth() async throws {
        let script = D1Stub.Script { _ in D1Stub.Reply(status: 401, body: D1Wire.authFailure) }
        let d1 = plugin(script: script)

        let thrown = await #expect(throws: (any Error).self) { try await d1.connect() }
        let error = try #require(thrown)
        let classified = ErrorClassifier.classify(error, context: connectContext)

        #expect(error.localizedDescription == String(localized: "Authentication failed. Check your API token and Account ID."))
        #expect(classified.category == .auth)
        #expect(classified.recovery == String(localized: "Check the API token and account of this connection."))
    }

    // A record synced without password sync arrives with no token.
    @Test("A connection missing its token or its account asks for them", arguments: [("", "acc123"), ("token", "")])
    func missingCredentialIsAuth(token: String, accountId: String) async throws {
        let script = account()
        let d1 = plugin(token: token, accountId: accountId, script: script)

        let thrown = await #expect(throws: (any Error).self) { try await d1.connect() }
        let classified = ErrorClassifier.classify(try #require(thrown), context: connectContext)

        #expect(classified.category == .auth)
        #expect(classified.recovery == String(localized: "Check the API token and account of this connection."))
        #expect(script.exchanges.isEmpty)
    }

    // MARK: - Bounded reads

    // D1 fails a result over 50 MB from 2026-11-04, so the editor's row cap is sent with the read.
    @Test("A read with no limit of its own is sent with one row past the cap, then trimmed and marked truncated")
    func boundedReadAppendsALimit() async throws {
        let script = account(raw: D1Wire.rows(["id"], "[[1],[2],[3]]"))
        let d1 = plugin(script: script)
        try await d1.connect()

        let bounded = try await d1.executeBoundedQuery(query: "SELECT * FROM events;", rowCap: 2)

        let result = try #require(bounded)
        #expect(script.sentSQL.last == "SELECT * FROM events\nLIMIT 3")
        #expect(result.rows == [["1"], ["2"]])
        #expect(result.isTruncated)
    }

    @Test("A table named fetch is no FETCH clause, so the read is still bounded")
    func tableNamedFetchIsBounded() async throws {
        let script = account(raw: D1Wire.rows(["id"], "[[1]]"))
        let d1 = plugin(script: script)
        try await d1.connect()

        _ = try await d1.executeBoundedQuery(query: "SELECT * FROM fetch", rowCap: 2)

        #expect(script.sentSQL.last == "SELECT * FROM fetch\nLIMIT 3")
    }

    @Test("A comment after the terminator stays out of the bounded statement")
    func commentAfterTerminatorIsDropped() async throws {
        let script = account(raw: D1Wire.rows(["id"], "[[1]]"))
        let d1 = plugin(script: script)
        try await d1.connect()

        _ = try await d1.executeBoundedQuery(query: "SELECT * FROM events; -- note", rowCap: 2)

        #expect(script.sentSQL.last == "SELECT * FROM events\nLIMIT 3")
    }

    @Test("A read that states its own limit is sent as written")
    func explicitLimitIsKept() async throws {
        let script = account(raw: D1Wire.rows(["id"], "[[1]]"))
        let d1 = plugin(script: script)
        try await d1.connect()

        _ = try await d1.executeBoundedQuery(query: "SELECT * FROM events LIMIT 5", rowCap: 2)

        #expect(script.sentSQL.last == "SELECT * FROM events LIMIT 5")
    }

    // Measured on sqlite3: `VALUES (1),(2)` with a LIMIT appended is a syntax error.
    @Test("A statement a LIMIT cannot follow is left to the plain path", arguments: [
        "VALUES (1), (2)", "PRAGMA table_info(events)", "INSERT INTO events VALUES (1)",
        "SELECT 1 UNION ALL VALUES (2)", "WITH t AS (SELECT 1) SELECT * FROM t UNION VALUES (2)"
    ])
    func unboundableStatementIsNotBounded(query: String) async throws {
        let script = account()
        let d1 = plugin(script: script)
        try await d1.connect()

        let bounded = try await d1.executeBoundedQuery(query: query, rowCap: 2)

        #expect(bounded == nil)
        #expect(script.sentSQL.isEmpty)
    }
}

// MARK: - Wire

private enum D1Wire {
    static func database(_ name: String, uuid: String) -> String {
        #"{"result":{"uuid":"\#(uuid)","name":"\#(name)","version":"production","created_at":"2026-01-01T00:00:00Z"},"success":true,"errors":[],"messages":[]}"#
    }

    static func rows(_ columns: [String], _ rows: String) -> String {
        let names = columns.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"result":[{"results":{"columns":[\#(names)],"rows":\#(rows)},"meta":{"duration":0.1,"changes":0},"success":true}],"success":true,"errors":[],"messages":[]}"#
    }

    static func list(_ names: [String], total: Int) -> String {
        let databases = names.map { #"{"uuid":"\#(UUID().uuidString.lowercased())","name":"\#($0)"}"# }.joined(separator: ",")
        return #"{"result":[\#(databases)],"success":true,"errors":[],"messages":[],"result_info":{"page":1,"per_page":10000,"count":\#(names.count),"total_count":\#(total)}}"#
    }

    static let notFound = #"{"result":null,"success":false,"errors":[{"code":7404,"message":"The database could not be found"}],"messages":[]}"#

    static let authFailure = #"{"result":null,"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"messages":[]}"#
}

// Answers each request from the script its session was made for, so cases running at once never share replies.
private final class D1Stub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body: String
    }

    struct Exchange: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let authorization: String?
        let sql: String?
    }

    final class Script: @unchecked Sendable {
        typealias Respond = @Sendable (Exchange) -> Reply

        fileprivate let id = UUID().uuidString
        private let respond: Respond
        private let lock = NSLock()
        private var recorded: [Exchange] = []

        init(_ respond: @escaping Respond) {
            self.respond = respond
            D1Stub.register(self)
        }

        var exchanges: [Exchange] {
            lock.withLock { recorded }
        }

        var sentSQL: [String] {
            exchanges.compactMap { $0.sql }
        }

        var configuration: URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [D1Stub.self]
            configuration.httpAdditionalHeaders = [D1Stub.routeHeader: id]
            return configuration
        }

        fileprivate func reply(to exchange: Exchange) -> Reply {
            lock.withLock { recorded.append(exchange) }
            return respond(exchange)
        }
    }

    private static let routeHeader = "X-D1-Stub-Route"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]

    fileprivate static func register(_ script: Script) {
        lock.withLock { scripts[script.id] = script }
    }

    private static func script(for request: URLRequest) -> Script? {
        guard let id = request.value(forHTTPHeaderField: routeHeader) else { return nil }
        return lock.withLock { scripts[id] }
    }

    // URLSession hands a custom protocol the body as a stream, not as httpBody.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func exchange(for request: URLRequest, url: URL) -> Exchange {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let json = try? JSONSerialization.jsonObject(with: body(of: request)) as? [String: Any]
        return Exchange(
            method: request.httpMethod ?? "GET",
            path: url.path,
            query: Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last }),
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            sql: json?["sql"] as? String
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let script = Self.script(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let reply = script.reply(to: Self.exchange(for: request, url: url))
        guard let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
