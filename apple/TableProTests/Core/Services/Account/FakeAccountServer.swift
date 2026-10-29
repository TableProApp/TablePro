//
//  FakeAccountServer.swift
//  TableProTests
//

import CryptoKit
import Foundation
@testable import TablePro
import TableProCloudAPI
import TableProTestSupport

// Answers /oauth/token, /oauth/revoke and the /v2 device and entitlement calls the way tablepro-cloud does.
actor FakeAccountServer {
    struct Request: Sendable {
        let method: String
        let path: String
        let form: [String: String]
        let json: [String: String]
        let authorization: String?
        var body = Data()
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

    let signingKey = Curve25519.Signing.PrivateKey()
    var features: [String] = ["icloud_sync", "query_insights"]
    var isOffline = false
    var refusesRefresh = false
    var deviceLimitReached = false
    var deviceRevoked = false
    var refusesRegistration = false
    var unauthorizedOnce = false
    var entitlementLifetime: TimeInterval = 14 * 24 * 60 * 60
    var licenses: [[String: Any]] = [FakeAccountServer.license()]
    var accountClaim: [String: Any] = ["email": "ada@m16.example", "name": "Ada"]
    var memberships: [[String: Any]] = []
    var devices: [[String: Any]] = [FakeAccountServer.device(id: FakeAccountServer.deviceID, name: "Test Mac", machineID: FakeAccountServer.machine.machineID)]
    var limitHolders: [[String: Any]] = [FakeAccountServer.device(
        id: "dev_other", name: "Workstation", machineID: String(repeating: "0", count: 64),
        platform: "linux", osVersion: "Fedora 43", licensed: true
    )]
    // Removing a device that holds a slot frees it, so the next entitlement answers.
    var removalFreesSlot = true
    var refreshGate: AsyncGate?
    var entitlementGate: AsyncGate?
    var library = FakeTeamLibrary()
    private(set) var requests: [Request] = []
    private(set) var familyBound = false
    private var familyMethod = "interactive"
    private var challenges: [String: String] = [:]
    private var refreshCounter = 0
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

    nonisolated var publicKey: Curve25519.Signing.PublicKey {
        signingKey.publicKey
    }

    // MARK: - OAuth

    // What the authorize page does: keeps the PKCE challenge under the code it hands back.
    func authorize(_ url: URL) -> String {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let code = "code-\(challenges.count + 1)"
        if query.first(where: { $0.name == "code_challenge_method" })?.value == "S256" {
            challenges[code] = query.first { $0.name == "code_challenge" }?.value
        }
        return code
    }

    func oauth(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let form = Self.parseForm(request.httpBody ?? Data())
        let path = request.url?.path ?? ""
        requests.append(Request(method: "POST", path: path, form: form, json: [:], authorization: nil))
        if isOffline { throw URLError(.notConnectedToInternet) }

        if path == "/oauth/revoke" {
            return Self.http(request, status: 200, body: [:])
        }
        switch form["grant_type"] {
        case "authorization_code":
            guard let code = form["code"], let challenge = challenges.removeValue(forKey: code),
                  let verifier = form["code_verifier"],
                  Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8)))) == challenge
            else {
                return Self.http(request, status: 400, body: ["error": "invalid_grant"])
            }
            familyBound = false
            familyMethod = "interactive"
            return tokens(request, device: false, method: familyMethod)
        case "refresh_token":
            refreshCounter += 1
            if let refreshGate { await refreshGate.wait() }
            guard !refusesRefresh, form["refresh_token"]?.hasPrefix("refresh-") == true else {
                return Self.http(request, status: 400, body: ["error": "invalid_grant"])
            }
            return tokens(request, device: familyBound, method: familyMethod)
        case OAuthTokenClient.tokenExchangeGrant:
            guard let key = form["subject_token"], [Self.validKey, Self.otherValidKey].contains(key) else {
                return Self.http(request, status: 400, body: ["error": "invalid_grant"])
            }
            familyBound = true
            familyMethod = "license_key"
            return tokens(request, device: true, method: familyMethod)
        default:
            return Self.http(request, status: 400, body: ["error": "unsupported_grant_type"])
        }
    }

    var refreshCount: Int { refreshCounter }

    private func tokens(_ request: URLRequest, device: Bool, method: String) -> (Data, URLResponse) {
        // Unique like the server's: two tokens with equal claims could serialize alike or not, by dictionary order.
        var claims: [String: Any] = ["sub": "acct_test", "auth_method": method, "jti": UUID().uuidString]
        if device { claims["dev"] = Self.deviceID }
        return Self.http(request, status: 200, body: [
            "access_token": Self.unsignedJWT(claims),
            "refresh_token": "refresh-\(UUID().uuidString)",
            "token_type": "Bearer",
            "expires_in": 900
        ])
    }

    // MARK: - /v2

    func api(_ request: HTTPRequest, body: HTTPBody?) async throws -> (HTTPResponse, HTTPBody?) {
        var data = Data()
        if let body {
            data = try await Data(collecting: body, upTo: 1_048_576)
        }
        let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
            .compactMapValues { $0 as? String }
        let path = request.path ?? ""
        let authorization = request.headerFields[.authorization]
        requests.append(Request(
            method: request.method.rawValue, path: path, form: [:], json: json, authorization: authorization, body: data
        ))
        if isOffline { throw URLError(.notConnectedToInternet) }
        if unauthorizedOnce {
            unauthorizedOnce = false
            return Self.problem(status: 401, code: "invalid_token")
        }

        let claims = authorization.flatMap { Self.claims(ofBearer: $0) } ?? [:]
        switch (request.method, path) {
        case (.post, "/devices"):
            if refusesRegistration {
                return Self.problem(status: 500, code: "internal")
            }
            familyBound = true
            return Self.json(status: .created, [
                "id": Self.deviceID, "machine_id": json["machine_id"] ?? "", "platform": "macos",
                "name": json["name"] ?? "", "app_version": json["app_version"] ?? "",
                "os_version": json["os_version"] ?? "", "created_at": "2026-10-01T09:00:00Z",
                "last_seen_at": "2026-10-28T09:00:00.123456Z"
            ])
        case (.post, "/devices/\(Self.deviceID)/entitlement"):
            if let entitlementGate { await entitlementGate.wait() }
            if deviceRevoked {
                return Self.problem(status: 403, code: "device_revoked")
            }
            guard claims["dev"] as? String == Self.deviceID else {
                return Self.problem(status: 403, code: "forbidden")
            }
            if deviceLimitReached {
                return Self.json(status: .conflict, contentType: "application/problem+json", [
                    "type": "https://api.tablepro.app/problems/device-limit-reached",
                    "title": "Device limit reached", "status": 409, "code": "device_limit_reached",
                    "devices": limitHolders
                ])
            }
            let token = signedEntitlement()
            return Self.json(status: .ok, [
                "token": token, "expires_at": "2026-11-10T00:00:00Z", "refresh_after": "2026-10-30T00:00:00Z"
            ])
        case (.get, "/me"):
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

    func signedEntitlement(machineID: String = FakeAccountServer.machine.machineID, offline: Bool = false) -> String {
        let issued = Int64(now().timeIntervalSince1970)
        return Self.sign(claims: [
            "iss": "https://api.tablepro.app", "aud": "tablepro-app", "sub": "acct_test",
            "jti": UUID().uuidString, "iat": issued, "nbf": issued,
            "exp": issued + Int64(entitlementLifetime), "dev": Self.deviceID, "mid": machineID,
            "features": features.sorted(),
            "licenses": licenses,
            "account": accountClaim,
            "offline": offline
        ], key: signingKey)
    }

    // MARK: - Helpers

    static func sign(
        claims: [String: Any],
        key: Curve25519.Signing.PrivateKey,
        header: [String: Any]? = nil
    ) -> String {
        let header = header ?? [
            "alg": "EdDSA", "kid": EntitlementVerifier.keyID(of: key.publicKey), "typ": "tablepro-entitlement+jwt"
        ]
        let head = Base64URL.encode(try! JSONSerialization.data(withJSONObject: header, options: .sortedKeys))
        let body = Base64URL.encode(try! JSONSerialization.data(withJSONObject: claims, options: .sortedKeys))
        let signature = try! key.signature(for: Data("\(head).\(body)".utf8))
        return "\(head).\(body).\(Base64URL.encode(signature))"
    }

    static func unsignedJWT(_ claims: [String: Any]) -> String {
        let head = Base64URL.encode(try! JSONSerialization.data(withJSONObject: ["alg": "EdDSA", "typ": "JWT"]))
        let body = Base64URL.encode(try! JSONSerialization.data(withJSONObject: claims))
        return "\(head).\(body).c2ln"
    }

    static func parseForm(_ data: Data) -> [String: String] {
        var form: [String: String] = [:]
        for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            form[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return form
    }

    private static func claims(ofBearer header: String) -> [String: Any]? {
        let token = header.replacingOccurrences(of: "Bearer ", with: "")
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Base64URL.decode(parts[1]) else { return nil }
        return try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    }

    private static func http(_ request: URLRequest, status: Int, body: [String: Any]) -> (Data, URLResponse) {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
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
        try await server.api(request, body: body)
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
    let services: AccountServices
    let keychain: InMemoryKeychain
    let legacyKeychain: InMemoryKeychain
    let defaults: EphemeralDefaults
    let entitlementFile: URL
    let access: FeatureAccess
    let clock = ManualClock()

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        verifyLegacy: @escaping @Sendable (SignedLicensePayload) throws -> LicensePayloadData = { $0.data }
    ) throws {
        let server = FakeAccountServer(now: now)
        let keychain = InMemoryKeychain()
        let legacyKeychain = InMemoryKeychain()
        let defaults = try EphemeralDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountTests-\(UUID().uuidString)", isDirectory: true)
        let entitlementFile = directory.appendingPathComponent("entitlement.jwt")
        let access = FeatureAccess(now: now)
        let configuration = AccountConfiguration(
            accountURL: URL(string: "http://account.localhost:5284")!,
            apiURL: URL(string: "http://api.localhost:5284")!,
            entitlementKeys: [server.publicKey]
        )
        self.server = server
        self.keychain = keychain
        self.legacyKeychain = legacyKeychain
        self.defaults = defaults
        self.entitlementFile = entitlementFile
        self.access = access
        self.services = AccountServices(
            configuration: configuration,
            machine: FakeAccountServer.machine,
            transport: FakeTransport(server: server),
            send: { request in try await server.oauth(request) },
            keychain: keychain,
            entitlementFile: entitlementFile,
            legacy: LegacyLicenseStore(
                keychain: legacyKeychain,
                defaults: defaults.defaults,
                machineID: FakeAccountServer.machine.machineID,
                verify: verifyLegacy
            ),
            access: access,
            clock: clock,
            now: now
        )
    }

    func storeLegacyLicense(key: String?, tier: String = "starter", issuedAt: Date = Date(), expiresAt: Date? = nil) throws {
        if let key {
            legacyKeychain.writeString(key, forKey: LegacyLicenseStore.keychainKey)
        }
        let formatter = ISO8601DateFormatter()
        let payload = LicensePayloadData(
            billingCycle: nil,
            licenseKey: key ?? FakeAccountServer.validKey,
            email: "ada@m16.example",
            status: "active",
            expiresAt: expiresAt.map { formatter.string(from: $0) },
            issuedAt: formatter.string(from: issuedAt),
            tier: tier,
            machineId: FakeAccountServer.machine.machineID
        )
        let cached = License(
            signedPayload: SignedLicensePayload(data: payload, signature: "sig"),
            cachedOnMachineId: FakeAccountServer.machine.machineID
        )
        defaults.defaults.set(try JSONEncoder().encode(cached), forKey: LegacyLicenseStore.payloadKey)
    }

    func signIn() async throws {
        try await services.signIn(using: FakeAuthenticator(server: server))
    }

    var hasLegacyLicense: Bool {
        defaults.defaults.data(forKey: LegacyLicenseStore.payloadKey) != nil
            || legacyKeychain.readStringResult(forKey: LegacyLicenseStore.keychainKey) != .notFound
    }
}
