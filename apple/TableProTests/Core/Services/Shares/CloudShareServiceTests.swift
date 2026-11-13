//
//  CloudShareServiceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProCloudAPI
import Testing

struct CloudShareServiceTests {
    private actor CannedTransport: ClientTransport {
        struct Sent: Sendable {
            let method: HTTPRequest.Method
            let path: String
            let headers: HTTPFields
            let body: Data
        }

        private var answers: [(HTTPResponse, HTTPBody?)]
        private(set) var sent: [Sent] = []

        init(_ answers: [(HTTPResponse, HTTPBody?)]) {
            self.answers = answers
        }

        func send(
            _ request: HTTPRequest,
            body: HTTPBody?,
            baseURL: URL,
            operationID: String
        ) async throws -> (HTTPResponse, HTTPBody?) {
            var data = Data()
            if let body {
                data = try await Data(collecting: body, upTo: 10 * 1_024 * 1_024)
            }
            sent.append(Sent(method: request.method, path: request.path ?? "", headers: request.headerFields, body: data))
            return answers.removeFirst()
        }
    }

    private static func service(_ transport: CannedTransport) -> CloudShareService {
        let client = Client(
            serverURL: URL(string: "https://api.example.test/v2")!,
            configuration: Configuration(dateTranscoder: RFC3339DateTranscoder()),
            transport: transport
        )
        return CloudShareService(
            api: client,
            publicAPI: client,
            createRequest: ShareCreateRequest(
                serverURL: URL(string: "https://api.example.test/v2")!,
                transport: transport,
                middlewares: []
            )
        )
    }

    private static func limitsJSON() -> [String: Any] {
        [
            "plan": "free", "live": 3, "live_limit": 5, "max_rows": 1_000,
            "expiries": ["1d", "7d", "30d"], "default_expiry": "30d",
            "password": false, "disable_download": false, "team": false,
            "email_verified": true, "sharing_disabled": false, "teams": [[String: Any]]()
        ]
    }

    private static func shareView(id: String, created: String, suspended: Bool = false) -> [String: Any] {
        [
            "id": id, "kind": "query", "scope": "account", "title": "T", "note": "", "dialect": "MySQL",
            "has_snapshot": false, "hide_sql": false, "allow_download": true, "has_password": false,
            "state": "live", "suspended": suspended, "view_count": 0, "created_at": created, "updated_at": created
        ]
    }

    @Test("Limits map every field the sheet reads")
    func limitsMap() async throws {
        let transport = CannedTransport([FakeAccountServer.json(status: .ok, Self.limitsJSON())])
        let limits = try await Self.service(transport).limits()

        #expect(limits == ShareLimits.free())
        #expect(await transport.sent.first?.path == "/share-limits")
    }

    @Test("Create sends the draft as the contract names it and returns the link")
    func createBody() async throws {
        let created: [String: Any] = [
            "share": Self.shareView(id: "shr_1", created: "2026-11-13T10:00:00Z"),
            "token": String(repeating: "a", count: 43),
            "url": "https://s.tablepro.app/" + String(repeating: "a", count: 43)
        ]
        let transport = CannedTransport([FakeAccountServer.json(status: .created, created)])
        let draft = ShareDraft(
            kind: .result,
            sql: "SELECT id FROM t",
            title: "T",
            note: nil,
            dialect: "PostgreSQL",
            expiry: .sevenDays,
            hidesSQL: true,
            allowsDownload: nil,
            password: nil,
            teamID: "team_1",
            snapshot: ShareSnapshot(
                columns: [.init(name: "id", type: "int8"), .init(name: "doc", type: "jsonb")],
                rows: [
                    [.number("18446744073709551615"), .document("{\"b\":1,\"a\":2}")],
                    [.number("7"), .array([.number("1"), .null])],
                    [.null, .string("x\"y")]
                ],
                rowCount: 48_210
            )
        )

        let link = try await Self.service(transport).create(draft)
        #expect(link.id == "shr_1")
        #expect(link.url.absoluteString.hasPrefix("https://s.tablepro.app/"))

        let sentRequest = try #require(await transport.sent.first)
        #expect(sentRequest.method == .post)
        #expect(sentRequest.path == "/shares")
        let body = sentRequest.body
        let text = try #require(String(data: body, encoding: .utf8))
        // Exact tokens and key order, which a Double or a dictionary would lose.
        #expect(text.contains("[18446744073709551615,{\"b\":1,\"a\":2}]"))
        #expect(text.contains("[7,[1,null]]"))
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["kind"] as? String == "result")
        #expect(sent["team_id"] as? String == "team_1")
        #expect(sent["expiry"] as? String == "7d")
        #expect(sent["hide_sql"] as? Bool == true)
        #expect(sent["allow_download"] == nil)
        #expect(sent["password"] == nil)
        #expect(sent["note"] == nil)
        let snapshot = try #require(sent["snapshot"] as? [String: Any])
        #expect((snapshot["row_count"] as? NSNumber)?.intValue == 48_210)
        let rows = try #require(snapshot["rows"] as? [[Any]])
        #expect(rows[2][0] is NSNull)
        #expect(rows[2][1] as? String == "x\"y")
    }

    @Test("A snapshot that is not cut, or whose total nobody counted, sends no row_count", arguments: [1, nil] as [Int?])
    func noRowCountUnlessCounted(total: Int?) {
        let text = ShareBodyWriter.snapshot(ShareSnapshot(columns: [.init(name: "a", type: nil)], rows: [[.number("1")]], rowCount: total))
        #expect(!text.contains("row_count"))
    }

    @Test("A column's name and type are cut to the contract's 256 characters")
    func columnTextIsCut() throws {
        let column = ShareSnapshot.Column(name: String(repeating: "é", count: 300), type: String(repeating: "t", count: 300))
        let text = ShareBodyWriter.snapshot(ShareSnapshot(columns: [column], rows: [], rowCount: 0))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let columns = try #require(object["columns"] as? [[String: String]])
        #expect(columns.first?["name"] == String(repeating: "é", count: 256))
        #expect(columns.first?["type"] == String(repeating: "t", count: 256))
    }

    @Test("Strings are escaped so the body stays valid JSON")
    func stringsAreEscaped() throws {
        let text = ShareBodyWriter.quoted("a\"b\\c\n\u{01}é")
        #expect(text == "\"a\\\"b\\\\c\\n\\u0001é\"")
        #expect(try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) as? String == "a\"b\\c\n\u{01}é")
    }

    @Test("Only a URL load that did not finish reads as offline")
    func offlineOnlyForURLErrors() {
        #expect(CloudShareService.failure(from: URLError(.notConnectedToInternet)) == .offline)
        #expect(CloudShareService.failure(from: URLError(.cancelled)) == .canceled)
        #expect(CloudShareService.failure(from: CancellationError()) == .canceled)
        #expect(CloudShareService.failure(from: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: ""))) == .server)
        #expect(CloudShareService.failure(from: AccountError.signedOut) == .signedOut)
    }

    @Test("The limits carry the seated teams")
    func limitsCarryTeams() async throws {
        var json = Self.limitsJSON()
        json["plan"] = "pro"
        json["teams"] = [["id": "team_1", "name": "Acme", "live": 4, "live_limit": 1_000, "public_links": false]]
        let transport = CannedTransport([FakeAccountServer.json(status: .ok, json)])
        let limits = try await Self.service(transport).limits()
        #expect(limits.teams == [ShareTeam(id: "team_1", name: "Acme", live: 4, liveLimit: 1_000, allowsPublicLinks: false)])
    }

    @Test("Problem codes reach the sheet as their own failures", arguments: [
        (403, "email_unverified", ShareFailure.emailUnverified),
        (403, "pro_required", .proRequired),
        (403, "sharing_disabled", .sharingDisabled),
        (403, "team_sharing_disabled", .teamSharingDisabled),
        (409, "share_limit_reached", .limitReached),
        (422, "snapshot_too_large", .snapshotTooLarge),
        (429, "rate_limited", .rateLimited),
        (401, "unauthorized", .signedOut)
    ])
    func problemCodes(status: Int, code: String, failure: ShareFailure) async {
        let transport = CannedTransport([FakeAccountServer.problem(status: status, code: code)])
        let draft = ShareDraft(
            kind: .query, sql: "SELECT 1", title: "", note: nil, dialect: nil, expiry: .thirtyDays,
            hidesSQL: nil, allowsDownload: nil, password: nil, teamID: nil, snapshot: nil
        )
        await #expect(throws: failure) {
            _ = try await Self.service(transport).create(draft)
        }
    }

    @Test("Live links ask for live ones only and come back oldest first")
    func liveLinksOldestFirst() async throws {
        let page: [String: Any] = ["data": [
            Self.shareView(id: "shr_new", created: "2026-11-13T10:00:00Z"),
            Self.shareView(id: "shr_old", created: "2026-11-01T10:00:00Z", suspended: true)
        ]]
        let transport = CannedTransport([FakeAccountServer.json(status: .ok, page)])
        let links = try await Self.service(transport).liveLinks(teamID: nil)

        #expect(links.map(\.id) == ["shr_old", "shr_new"])
        #expect(links.map(\.isSuspended) == [true, false])
        let path = try #require(await transport.sent.first?.path)
        #expect(path.hasPrefix("/shares?"))
        #expect(path.contains("state=live"))
        #expect(!path.contains("team="))
    }

    @Test("A team's live links are asked for by its ID")
    func teamLiveLinks() async throws {
        let transport = CannedTransport([FakeAccountServer.json(status: .ok, ["data": [[String: Any]]()])])
        _ = try await Self.service(transport).liveLinks(teamID: "team_1")
        let path = try #require(await transport.sent.first?.path)
        #expect(path.contains("team=team_1"))
    }

    @Test("Revoke deletes the share by its ID")
    func revokeDeletes() async throws {
        let transport = CannedTransport([(HTTPResponse(status: .noContent), nil)])
        try await Self.service(transport).revoke(id: "shr_1")
        let sent = try #require(await transport.sent.first)
        #expect(sent.method == .delete)
        #expect(sent.path == "/shares/shr_1")
    }

    @Test("The public read sends the password header and tells required from wrong")
    func publicReadPassword() async throws {
        let shared: [String: Any] = [
            "kind": "result", "title": "Report", "note": "", "dialect": "MySQL",
            "created_at": "2026-11-13T10:00:00Z", "allow_download": true, "made_with": "TablePro"
        ]
        let transport = CannedTransport([
            FakeAccountServer.problem(status: 401, code: "share_password_required"),
            FakeAccountServer.problem(status: 401, code: "share_password_wrong"),
            FakeAccountServer.json(status: .ok, shared)
        ])
        let service = Self.service(transport)
        let token = String(repeating: "b", count: 43)

        await #expect(throws: ShareFailure.passwordRequired) { _ = try await service.fetchShared(token: token, password: nil) }
        await #expect(throws: ShareFailure.passwordWrong) { _ = try await service.fetchShared(token: token, password: "nope") }
        let query = try await service.fetchShared(token: token, password: "right")

        #expect(query == SharedQuery(kind: .result, title: "Report", sql: nil))
        let sent = await transport.sent
        #expect(sent[0].headers[HTTPField.Name("X-Share-Password")!] == nil)
        #expect(sent[2].headers[HTTPField.Name("X-Share-Password")!] == "right")
        #expect(sent[2].headers[.authorization] == nil)
    }
}
