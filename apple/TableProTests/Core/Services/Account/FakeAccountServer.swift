//
//  FakeAccountServer.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProCloudAPI
import TableProTestSupport

// tablepro-cloud as the tests see it: the /v2 calls the Swift clients make through FakeTransport, and the account
// state FakeAccountBackend reads the way the core reads its answers.
actor FakeAccountServer {
    struct Request: Sendable {
        let method: String
        let path: String
        let form: [String: String]
        let json: [String: String]
        let authorization: String?
        var body = Data()
        var baseURL: URL?
    }

    static let machine = MachineDescription(
        machineID: String(repeating: "ab", count: 32),
        name: "Test Mac",
        appVersion: "2.0.0",
        osVersion: "26.1"
    )
    static let deviceID = "dev_01k8d6wpggfd68tbhz818p4ww4"
    static let validKey = "ABCDE-FGHIJ-KLMNO-PQRST-UVWXY"
    static let otherValidKey = "VWXYZ-QRSTU-LMNOP-GHIJK-ABCDE"

    var features: [String] = ["icloud_sync", "query_insights"]
    var isOffline = false
    var refusesRefresh = false
    var deviceLimitReached = false
    var deviceRevoked = false
    var unauthorizedOnce = false
    var entitlementLifetime: TimeInterval = 14 * 24 * 60 * 60
    var licenses: [[String: Any]] = [FakeAccountServer.license()]
    var accountID = "acct_test"
    var accountClaim: [String: Any] = ["email": "ada@m16.example", "name": "Ada"]
    var memberships: [[String: Any]] = []
    var devices: [[String: Any]] = [FakeAccountServer.device(id: FakeAccountServer.deviceID, name: "Test Mac", machineID: FakeAccountServer.machine.machineID)]
    var limitHolders: [[String: Any]] = [FakeAccountServer.device(
        id: "dev_other", name: "Workstation", machineID: String(repeating: "0", count: 64),
        platform: "linux", osVersion: "Fedora 43", licensed: true
    )]
    // Removing a device that holds a slot frees it, so the next entitlement answers.
    var removalFreesSlot = true
    var library = FakeTeamLibrary()
    // Answered, one per GET /me, before anything else; a 429 carries the library's Retry-After.
    var profileFaults: [Int] = []
    private(set) var requests: [Request] = []
    private var authorizations = 0
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func set(_ change: @Sendable (isolated FakeAccountServer) -> Void) {
        change(self)
    }

    func requests(to path: String) -> [Request] {
        requests.filter { $0.path == path }
    }

    // MARK: - OAuth

    // What the authorize page does: hands back a code for the sign-in's state.
    func authorize(_ url: URL) -> String {
        authorizations += 1
        return "code-\(authorizations)"
    }

    // What the core reads from the server for a sign-in or a refresh.
    func entitlementAnswer() -> FakeEntitlementAnswer {
        FakeEntitlementAnswer(
            isOffline: isOffline,
            refusesRefresh: refusesRefresh,
            deviceRevoked: deviceRevoked,
            deviceLimitReached: deviceLimitReached,
            limitHolders: limitHolders,
            accountID: accountID,
            accountClaim: accountClaim,
            features: features,
            licenses: licenses,
            lifetime: entitlementLifetime
        )
    }

    // MARK: - /v2

    func api(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL? = nil) async throws -> (HTTPResponse, HTTPBody?) {
        var data = Data()
        if let body {
            data = try await Data(collecting: body, upTo: 1_048_576)
        }
        let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
            .compactMapValues { $0 as? String }
        let path = request.path ?? ""
        let authorization = request.headerFields[.authorization]
        requests.append(Request(
            method: request.method.rawValue, path: path, form: [:], json: json, authorization: authorization, body: data,
            baseURL: baseURL
        ))
        if isOffline { throw URLError(.notConnectedToInternet) }
        if unauthorizedOnce {
            unauthorizedOnce = false
            return Self.problem(status: 401, code: "invalid_token")
        }

        switch (request.method, path) {
        case (.get, "/me"):
            if !profileFaults.isEmpty {
                return library.fault(profileFaults.removeFirst())
            }
            var account = accountClaim
            account["id"] = "acct_test"
            return Self.json(status: .ok, [
                "account": account,
                "teams": memberships,
                "licenses": licenses.map { $0.filter { !($0.value is NSNull) } }
            ])
        case (.get, let listPath) where listPath.hasPrefix("/devices?") || listPath == "/devices":
            return Self.json(status: .ok, ["data": devices])
        case (.delete, let devicePath) where devicePath.hasPrefix("/devices/"):
            return removeDevice(String(devicePath.dropFirst("/devices/".count)))
        case (.get, let libraryPath) where libraryPath.hasPrefix("/teams/"):
            if let gate = library.pullGate { await gate.wait() }
            return library.pull(path: libraryPath, memberships: memberships)
        case (.post, let libraryPath) where libraryPath.hasPrefix("/teams/"):
            if let gate = library.pushGate { await gate.wait() }
            return library.push(path: libraryPath, body: data, memberships: memberships)
        default:
            return Self.problem(status: 404, code: "not_found")
        }
    }

    private func removeDevice(_ id: String) -> (HTTPResponse, HTTPBody?) {
        let all = devices + limitHolders
        guard let device = all.first(where: { $0["id"] as? String == id }) else {
            return Self.problem(status: 404, code: "not_found")
        }
        if let until = (device["offline_until"] as? String).flatMap({ try? Date($0, strategy: .iso8601) }), until > now() {
            return Self.problem(status: 409, code: "offline_file_active")
        }
        devices.removeAll { $0["id"] as? String == id }
        limitHolders.removeAll { $0["id"] as? String == id }
        if removalFreesSlot {
            deviceLimitReached = false
        }
        return (HTTPResponse(status: .noContent), nil)
    }

    static func license(
        id: String = "lic_test",
        plan: String = "starter",
        cycle: String = "lifetime",
        source: String = "order",
        status: String = "active",
        renewsAt: String? = nil,
        endsAt: String? = nil,
        team: (id: String, name: String)? = nil
    ) -> [String: Any] {
        [
            "id": id, "plan": plan, "cycle": cycle, "source": source, "status": status,
            "renews_at": renewsAt ?? NSNull(),
            "ends_at": endsAt ?? NSNull(),
            "team": team.map { ["id": $0.id, "name": $0.name] } ?? NSNull()
        ]
    }

    static func device(
        id: String,
        name: String,
        machineID: String,
        platform: String = "macos",
        osVersion: String = "26.1",
        lastSeen: String = "2026-10-28T09:00:00Z",
        licensed: Bool = true,
        offlineUntil: String? = nil
    ) -> [String: Any] {
        var device: [String: Any] = [
            "id": id, "machine_id": machineID, "platform": platform, "name": name, "app_version": "2.0.0",
            "os_version": osVersion, "created_at": "2026-10-01T09:00:00Z", "last_seen_at": lastSeen
        ]
        if licensed { device["licensed_at"] = "2026-10-01T09:00:00Z" }
        if let offlineUntil { device["offline_until"] = offlineUntil }
        return device
    }

    static func membership(teamID: String, name: String, role: String, hasSeat: Bool) -> [String: Any] {
        ["team": ["id": teamID, "name": name], "role": role, "has_seat": hasSeat]
    }

    static func unsignedJWT(_ claims: [String: Any]) -> String {
        let head = Base64URL.encode(try! JSONSerialization.data(withJSONObject: ["alg": "EdDSA", "typ": "JWT"]))
        let body = Base64URL.encode(try! JSONSerialization.data(withJSONObject: claims))
        return "\(head).\(body).c2ln"
    }

    static func json(
        status: HTTPResponse.Status,
        contentType: String = "application/json",
        _ body: [String: Any]
    ) -> (HTTPResponse, HTTPBody?) {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = contentType
        return (response, HTTPBody(data))
    }

    static func problem(status: Int, code: String) -> (HTTPResponse, HTTPBody?) {
        json(status: .init(code: status), contentType: "application/problem+json", [
            "type": "https://api.tablepro.app/problems/\(code)", "title": code, "status": status, "code": code
        ])
    }
}

struct FakeTransport: ClientTransport {
    let server: FakeAccountServer

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        try await server.api(request, body: body, baseURL: baseURL)
    }
}

@MainActor
struct FakeAuthenticator: WebAuthenticating {
    let server: FakeAccountServer

    func authenticate(url: URL, callbackScheme: String) async throws(AccountError) -> URL {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        let code = await server.authorize(url)
        return URL(string: "app.tablepro:/oauth/callback?code=\(code)&state=\(state)")!
    }
}

@MainActor
struct AccountFixture {
    let server: FakeAccountServer
    let backend: FakeAccountBackend
    let services: AccountServices
    // Where an older build kept its license key.
    let keychain: InMemoryKeychain
    let defaults: EphemeralDefaults
    let access: FeatureAccess
    let clock = ManualClock()

    init(now: @escaping @Sendable () -> Date = { Date() }) throws {
        let server = FakeAccountServer(now: now)
        let keychain = InMemoryKeychain()
        let defaults = try EphemeralDefaults()
        let access = FeatureAccess(now: now)
        let backend = FakeAccountBackend(server: server, now: now)
        self.server = server
        self.backend = backend
        self.keychain = keychain
        self.defaults = defaults
        self.access = access
        self.services = AccountServices(
            backend: backend,
            transport: FakeTransport(server: server),
            storedKey: StoredLicenseKey(
                keychain: keychain, defaults: defaults.defaults, machineID: FakeAccountServer.machine.machineID
            ),
            access: access,
            clock: clock,
            now: now
        )
        backend.listener = services
    }

    // A key an older build stored, with the signed payload it kept beside it.
    func storeLegacyLicense(key: String) {
        keychain.writeString(key, forKey: StoredLicenseKey.keychainKey)
        storeLegacyPayload(key: key)
    }

    // The payload alone, as on a Mac whose Keychain copy another Mac's migration deleted.
    func storeLegacyPayload(key: String, cachedOn machineID: String = FakeAccountServer.machine.machineID) {
        let cached: [String: Any] = [
            "signedPayload": ["data": ["license_key": key, "email": "ada@m16.example", "status": "active"], "signature": "sig"],
            "machineId": machineID
        ]
        defaults.defaults.set(try? JSONSerialization.data(withJSONObject: cached), forKey: StoredLicenseKey.payloadKey)
    }

    func signIn() async throws {
        try await services.signIn(using: FakeAuthenticator(server: server))
    }

    var hasLegacyLicense: Bool {
        defaults.defaults.data(forKey: StoredLicenseKey.payloadKey) != nil
            || keychain.readStringResult(forKey: StoredLicenseKey.keychainKey) != .notFound
    }
}
