import Foundation
@testable import TableProGoogleCloud
import Testing

private final class ScriptedTransport: GoogleRESTTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Int]
    private var sent: [GoogleRESTRequest] = []

    init(statuses: [Int]) {
        self.statuses = statuses
    }

    var requests: [GoogleRESTRequest] {
        lock.withLock { sent }
    }

    func send(_ request: GoogleRESTRequest) async throws -> GoogleRESTResponse {
        let status = lock.withLock {
            sent.append(request)
            return statuses.isEmpty ? 200 : statuses.removeFirst()
        }
        return GoogleRESTResponse(statusCode: status, body: Data())
    }

    func cancelAll() {}
}

struct GoogleRESTRequesterTests {
    private let url = URL(string: "https://bigtable.googleapis.com/v2/x") ?? URL(fileURLWithPath: "/")

    @Test("A 401 drops the cached token and retries once with a fresh one")
    func unauthorizedRetriesOnce() async throws {
        let transport = ScriptedTransport(statuses: [401, 401])
        let tokens = LockedBox(["stale", "fresh"])
        let credential = GoogleRESTCredential(
            token: { tokens.value.first },
            invalidate: { tokens.mutate { $0.removeFirst() } }
        )
        let response = try await GoogleRESTRequester(transport: transport, credential: credential, timeout: { 5 })
            .send(method: "GET", url: url)

        #expect(response.statusCode == 401)
        #expect(transport.requests.map { $0.headers["Authorization"] } == ["Bearer stale", "Bearer fresh"])
    }

    @Test("A body is sent as JSON, a login's quota project is billed, and the caller's own quota header wins")
    func headers() async throws {
        let transport = ScriptedTransport(statuses: [])
        let requester = GoogleRESTRequester(
            transport: transport, credential: GoogleRESTCredential(token: { "t" }, quotaProject: "quota"), timeout: { 7 }
        )
        _ = try await requester.send(method: "POST", url: url, body: Data("{}".utf8))
        _ = try await requester.send(method: "GET", url: url, headers: ["x-goog-user-project": "browsed"], timeoutOverride: 2)

        let first = try #require(transport.requests.first)
        #expect(first.headers["Content-Type"] == "application/json")
        #expect(first.headers["x-goog-user-project"] == "quota")
        #expect(first.timeoutInterval == 7)
        let second = try #require(transport.requests.last)
        #expect(second.headers["Content-Type"] == nil)
        #expect(second.headers["x-goog-user-project"] == "browsed")
        #expect(second.timeoutInterval == 2)
    }

    @Test("A credential with no token sends no Authorization header")
    func tokenlessCredential() async throws {
        let transport = ScriptedTransport(statuses: [])
        _ = try await GoogleRESTRequester(transport: transport, credential: GoogleRESTCredential(token: { nil }), timeout: { 5 })
            .send(method: "GET", url: url)
        #expect(transport.requests.first?.headers["Authorization"] == nil)
    }

    @Test("Application Default Credentials that name no project fall back to GOOGLE_CLOUD_PROJECT")
    func projectHintFromEnvironment() throws {
        let login = #"{"type":"authorized_user","client_id":"cid","client_secret":"cs","refresh_token":"1//rt"}"#
        let resolved = try GoogleRESTCredential.resolving(
            .applicationDefault,
            scopes: [GoogleOAuthClient.cloudPlatformScope],
            environment: ["GOOGLE_CLOUD_PROJECT": " env-proj "],
            readFile: { $0 == GoogleApplicationDefaultCredentials.defaultPath ? Data(login.utf8) : nil },
            http: StubGoogleHTTPClient(json: "{}")
        )
        #expect(resolved.projectHint == "env-proj")
        #expect(resolved.credential.quotaProject == nil)
    }

    @Test("A service account key names its own project, whatever the environment says")
    func projectHintFromKey() throws {
        let rsa = try #require(TestRSAKey.shared)
        let resolved = try GoogleRESTCredential.resolving(
            .serviceAccountKey(rsa.serviceAccountJSON(projectId: "key-project")),
            scopes: [GoogleOAuthClient.cloudPlatformScope],
            environment: ["GOOGLE_CLOUD_PROJECT": "env-proj"],
            readFile: { _ in nil },
            http: StubGoogleHTTPClient(json: "{}")
        )
        #expect(resolved.projectHint == "key-project")
    }
}
