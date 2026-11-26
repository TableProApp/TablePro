//
//  FakeAccountBackend.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProCloudAPI
import TableProFFI

struct FakeEntitlementAnswer: @unchecked Sendable {
    let isOffline: Bool
    let refusesRefresh: Bool
    let deviceRevoked: Bool
    let deviceLimitReached: Bool
    let limitHolders: [[String: Any]]
    let accountID: String
    let accountClaim: [String: Any]
    let features: [String]
    let licenses: [[String: Any]]
    let lifetime: TimeInterval
}

// What the core's AccountService does, over FakeAccountServer: the sign-in through the host's authenticator, the
// entitlement, the sign-out causes on the listener, the server choice and the bearer.
final class FakeAccountBackend: AccountBackend, @unchecked Sendable {
    static let companyServer = AccountServer(
        apiOrigin: URL(string: "https://tablepro.example.com")!,
        accountOrigin: URL(string: "https://account.tablepro.example.com")!,
        host: "tablepro.example.com",
        isProduction: false,
        isManaged: false,
        othersAllowed: true
    )

    let fakeServer: FakeAccountServer
    let machineID = FakeAccountServer.machine.machineID
    @MainActor weak var listener: (any AccountBackendListener)?

    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var snapshot = AccountSnapshot()
    // The person's choice; nil takes a configuration profile's default, else tablepro.app.
    private var chosen: AccountServer?
    private var managed: AccountServer?
    private var restored = true
    private var restoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingRestore: AccountSnapshot?
    private var serverLicense: AccountServerLicense?
    private var refusedAddresses: [String: AccountError.CompanyServerProblem] = [:]
    private var rejectedTokens: [String] = []
    private var tokenCount = 0
    private var refreshCalls = 0
    private var keychainRefuses = false
    private var bearerFailure: AccountError?
    private var allowsTableProRequestsValue = true
    private var policies: [ManagedPolicyArg] = []
    private var stepUps: [[String]] = []
    // Runs as the core is told its token was refused, as if the person changed server at that moment.
    var onTokenRejected: (@Sendable (FakeAccountBackend) -> Void)?

    init(server: FakeAccountServer, now: @escaping @Sendable () -> Date) {
        self.fakeServer = server
        self.now = now
    }

    // MARK: - Test controls

    // What a configuration profile hands the core.
    func manage(_ server: AccountServer?) {
        locked { managed = server }
    }

    // As the core while a profile holds the app to a company server.
    func holdTableProRequests(_ held: Bool) {
        locked { allowsTableProRequestsValue = !held }
    }

    var appliedPolicies: [ManagedPolicyArg] {
        locked { policies }
    }

    func refuse(_ host: String, with problem: AccountError.CompanyServerProblem) {
        locked { refusedAddresses[host] = problem }
    }

    func installLicense(_ license: AccountServerLicense?) {
        locked { serverLicense = license }
    }

    // As the core when renewing the bearer fails, such as an OAuth temporarily_unavailable.
    func failBearer(with error: AccountError?) {
        locked { bearerFailure = error }
    }

    // As the core when the Keychain refuses the refresh token: signed in for this run only.
    func refuseKeychain() {
        locked { keychainRefuses = true }
    }

    // A launch on which the core has not opened yet: signed out on tablepro.app, as CoreAccountBackend reads then,
    // until finishRestore hands over what the last run kept.
    func restoreLater(_ kept: AccountSnapshot) {
        locked {
            restored = false
            pendingRestore = kept
            snapshot = AccountSnapshot()
        }
    }

    var isWaitingForRestore: Bool {
        locked { !restoreWaiters.isEmpty }
    }

    @MainActor
    func finishRestore() {
        let waiting = locked { () -> [CheckedContinuation<Void, Never>] in
            restored = true
            snapshot = pendingRestore ?? snapshot
            pendingRestore = nil
            defer { restoreWaiters = [] }
            return restoreWaiters
        }
        waiting.forEach { $0.resume() }
        listener?.accountStatusChanged(signedOutBy: nil)
    }

    var tokensRejected: [String] {
        locked { rejectedTokens }
    }

    var refreshCount: Int {
        locked { refreshCalls }
    }

    // An offline file in the shape this fake reads.
    static func offlineFile(in directory: URL, machineID: String, expiresAt: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("tablepro-offline-\(machineID.prefix(12)).jwt")
        let body: [String: Any] = [
            "sub": "acct_test", "email": "ada@m16.example", "machine_id": machineID,
            "features": ["icloud_sync"], "exp": expiresAt.timeIntervalSince1970
        ]
        try JSONSerialization.data(withJSONObject: body).write(to: file)
        return file
    }

    // MARK: - AccountBackend

    var isRestored: Bool {
        locked { restored }
    }

    func waitUntilRestored() async {
        await withCheckedContinuation { continuation in
            let resumeNow = locked { () -> Bool in
                guard !restored else { return true }
                restoreWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func status() -> AccountSnapshot {
        locked { snapshot }
    }

    func featureAccess(code: String) -> ProFeatureAccess {
        let snapshot = status()
        let current = snapshot.expiresAt.map { now() < $0 } ?? false
        switch snapshot.state {
        case .signedOut:
            return .signedOut
        case .offline:
            guard current else { return .expired }
            return snapshot.features.contains(code) ? .available : .notIncluded
        case .signedIn:
            // As the core: past a company license's grace only the Team Library works.
            if let graceEndsAt = license()?.graceEndsAt, now() >= graceEndsAt, code != ProFeature.teamLibrary.rawValue,
               snapshot.features.contains(code) {
                return .expired
            }
            if current {
                return snapshot.features.contains(code) ? .available : .notIncluded
            }
            switch snapshot.problem {
            case .deviceLimitReached: return .notIncluded
            case .refreshFailed: return .refreshFailed
            case .expired: return .expired
            case nil: return snapshot.expiresAt == nil ? .notIncluded : .expired
            }
        }
    }

    func server() -> AccountServer {
        locked { restored ? resolved() : .production }
    }

    func license() -> AccountServerLicense? {
        locked { !restored || resolved().isProduction ? nil : serverLicense }
    }

    func signIn(using authenticator: any WebAuthenticating) async throws(AccountError) {
        let origin = server().accountOrigin
        let url = URL(string: "\(origin.absoluteString)/oauth/authorize?client_id=tablepro-macos&state=fake")!
        let callback = try await authenticator.authenticate(url: url, callbackScheme: "app.tablepro")
        guard URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(where: { $0.name == "code" }) == true
        else { throw .invalidResponse }
        try await adopt(await fakeServer.entitlementAnswer(), refreshing: false)
    }

    // As the core: the sign-in page with the challenge's values, and the same account's session after it.
    func stepUp(acrValues: [String], maxAgeSecs: UInt64?, using authenticator: any WebAuthenticating) async throws(AccountError) {
        guard status().state == .signedIn else { throw .signedOut }
        var query = URLComponents(string: "\(server().accountOrigin.absoluteString)/oauth/authorize")!
        query.queryItems = [URLQueryItem(name: "acr_values", value: acrValues.joined(separator: " "))]
            + (maxAgeSecs.map { [URLQueryItem(name: "max_age", value: String($0))] } ?? [])
        let callback = try await authenticator.authenticate(url: query.url!, callbackScheme: "app.tablepro")
        guard URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(where: { $0.name == "code" }) == true
        else { throw .invalidResponse }
        locked { stepUps.append(acrValues) }
    }

    var stepUpChallenges: [[String]] {
        locked { stepUps }
    }

    func signOut() async throws(AccountError) {
        locked { snapshot = AccountSnapshot() }
    }

    func refresh() async throws(AccountError) {
        locked { refreshCalls += 1 }
        guard status().state == .signedIn else { throw .signedOut }
        try await adopt(await fakeServer.entitlementAnswer(), refreshing: true)
    }

    func refreshPastDeviceLimit() async throws(AccountError) -> Bool {
        guard case .deviceLimitReached = status().problem else { return false }
        try await refresh()
        return true
    }

    func useLicenseKey(_ key: String) async throws(AccountError) {
        let answer = await fakeServer.entitlementAnswer()
        if answer.isOffline { throw .network("offline") }
        guard [FakeAccountServer.validKey, FakeAccountServer.otherValidKey].contains(key) else {
            throw .oauth("invalid_grant", description: nil)
        }
        try await adopt(answer, refreshing: false)
    }

    func importOfflineFile(at url: URL) async throws(AccountError) {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw .offlineFileRejected(.unreadable) }
        guard file["machine_id"] as? String == machineID else { throw .offlineFileRejected(.otherMachine) }
        let expiresAt = Date(timeIntervalSince1970: file["exp"] as? TimeInterval ?? 0)
        guard expiresAt > now() else { throw .offlineFileRejected(.expired) }
        let refusal: AccountError? = locked {
            if !resolved().isProduction { return .companyServer(.unsupported) }
            if snapshot.state == .signedIn, snapshot.accountID != file["sub"] as? String { return .offlineFileRejected(.otherAccount) }
            return nil
        }
        if let refusal { throw refusal }
        locked {
            // As the core: a signed-in Mac keeps its sign-in and takes the file's entitlement.
            if snapshot.state == .signedIn {
                snapshot.features = Set(file["features"] as? [String] ?? [])
                snapshot.expiresAt = expiresAt
                snapshot.isOfflineFile = true
                snapshot.problem = nil
                return
            }
            snapshot = AccountSnapshot(
                state: .offline,
                accountID: file["sub"] as? String,
                email: file["email"] as? String,
                name: "Ada",
                features: Set(file["features"] as? [String] ?? []),
                licenses: [Self.license(FakeAccountServer.license())],
                expiresAt: expiresAt,
                isOfflineFile: true
            )
        }
    }

    func chooseServer(_ url: URL?) async throws(AccountError) {
        let refusal: AccountError? = locked {
            if managed?.othersAllowed == false { return .companyServer(.managed) }
            if let host = url?.host, let problem = refusedAddresses[host] { return .companyServer(problem) }
            return nil
        }
        if let refusal { throw refusal }
        locked {
            snapshot = AccountSnapshot()
            if let url, url == AccountServer.production.apiOrigin {
                chosen = .production
            } else if let url, let host = url.host {
                chosen = AccountServer(
                    apiOrigin: url,
                    accountOrigin: url,
                    host: host,
                    isProduction: false,
                    isManaged: false,
                    othersAllowed: true
                )
            } else {
                chosen = nil
            }
        }
    }

    func profile() async throws(AccountError) -> AccountProfile {
        let me = try await call(.get, "/me")
        let account = me["account"] as? [String: Any] ?? [:]
        let teams = me["teams"] as? [[String: Any]] ?? []
        return AccountProfile(
            email: account["email"] as? String ?? "",
            name: account["name"] as? String,
            memberships: teams.map { membership in
                let team = membership["team"] as? [String: Any] ?? [:]
                return AccountMembership(
                    teamID: team["id"] as? String ?? "",
                    teamName: team["name"] as? String ?? "",
                    role: membership["role"] as? String ?? "",
                    hasSeat: membership["has_seat"] as? Bool ?? false
                )
            }
        )
    }

    func devices() async throws(AccountError) -> [AccountDevice] {
        let list = try await call(.get, "/devices")
        return (list["data"] as? [[String: Any]] ?? []).map(Self.device)
    }

    func removeDevice(_ id: String) async throws(AccountError) {
        _ = try await call(.delete, "/devices/\(id)")
    }

    func accessToken() async throws(AccountError) -> AccountAccessToken {
        if let failure = locked({ bearerFailure }) { throw failure }
        let snapshot = status()
        guard snapshot.state == .signedIn, let accountID = snapshot.accountID else { throw .signedOut }
        let (count, server) = locked {
            tokenCount += 1
            return (tokenCount, resolved())
        }
        let token = FakeAccountServer.unsignedJWT([
            "sub": accountID, "dev": FakeAccountServer.deviceID, "jti": "token-\(count)"
        ])
        return AccountAccessToken(token: token, apiBaseURL: server.apiBaseURL, sessionID: snapshot.sessionID)
    }

    func accessTokenRejected(_ token: String) async {
        locked { rejectedTokens.append(token) }
        onTokenRejected?(self)
    }

    func applyPolicy(_ policy: ManagedPolicyArg) async {
        locked { policies.append(policy) }
    }

    func allowsTableProRequests() async -> Bool {
        locked { allowsTableProRequestsValue }
    }

    func switchServerKeepingTheSession(to server: AccountServer) {
        locked { chosen = server }
    }

    // MARK: - Private

    // As the core resolves it: a profile's server that allows no other, the person's choice, the profile's default,
    // tablepro.app. Call it holding the lock.
    private func resolved() -> AccountServer {
        if let managed, !managed.othersAllowed { return managed }
        return chosen ?? managed ?? .production
    }

    private func adopt(_ answer: FakeEntitlementAnswer, refreshing: Bool) async throws(AccountError) {
        if answer.isOffline {
            if refreshing {
                locked { snapshot.problem = .refreshFailed(.network("offline")) }
            }
            throw .network("offline")
        }
        if refreshing, answer.refusesRefresh {
            await signOutHere(.refreshRefused)
            throw .signedOut
        }
        if answer.deviceRevoked {
            await signOutHere(.deviceRevoked)
            throw .server(status: 403, code: "device_revoked")
        }
        let account = answer.accountClaim
        let name = (account["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expiresAt = now().addingTimeInterval(answer.lifetime)
        locked {
            var next = AccountSnapshot(state: .signedIn, remembered: !keychainRefuses)
            // As the core: a refresh keeps the sign-in's id, a new sign-in gets its own.
            next.sessionID = refreshing ? snapshot.sessionID : UUID().uuidString
            next.accountID = answer.accountID
            next.email = account["email"] as? String
            next.name = name
            if answer.deviceLimitReached {
                next.problem = .deviceLimitReached(answer.limitHolders.map(Self.device))
                if snapshot.accountID == answer.accountID {
                    next.features = snapshot.features
                    next.licenses = snapshot.licenses
                    next.expiresAt = snapshot.expiresAt
                    next.isOfflineFile = snapshot.isOfflineFile
                }
            } else {
                next.features = Set(answer.features)
                next.licenses = answer.licenses.map(Self.license)
                next.expiresAt = expiresAt
            }
            snapshot = next
        }
    }

    private func signOutHere(_ cause: AccountSignOutCause) async {
        locked { snapshot = AccountSnapshot() }
        await MainActor.run { listener?.accountStatusChanged(signedOutBy: cause) }
    }

    private func call(_ method: HTTPRequest.Method, _ path: String) async throws(AccountError) -> [String: Any] {
        let response: HTTPResponse
        let body: HTTPBody?
        do {
            (response, body) = try await fakeServer.api(HTTPRequest(method: method, scheme: nil, authority: nil, path: path), body: nil)
        } catch {
            throw .network(error.localizedDescription)
        }
        var data = Data()
        if let body {
            data = (try? await Data(collecting: body, upTo: 1_048_576)) ?? Data()
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(response.status.code) else {
            throw .server(status: response.status.code, code: json["code"] as? String)
        }
        return json
    }

    private static func device(_ json: [String: Any]) -> AccountDevice {
        AccountDevice(
            id: json["id"] as? String ?? "",
            isThisDevice: json["machine_id"] as? String == FakeAccountServer.machine.machineID,
            name: json["name"] as? String ?? "",
            platform: json["platform"] as? String ?? "",
            osVersion: json["os_version"] as? String ?? "",
            lastSeenAt: date(json["last_seen_at"]) ?? .distantPast,
            holdsLicense: json["licensed_at"] != nil,
            offlineUntil: date(json["offline_until"])
        )
    }

    private static func license(_ json: [String: Any]) -> EntitlementLicense {
        let team = json["team"] as? [String: Any]
        return EntitlementLicense(
            id: json["id"] as? String ?? "",
            plan: json["plan"] as? String ?? "",
            cycle: json["cycle"] as? String ?? "",
            source: json["source"] as? String ?? "",
            status: json["status"] as? String ?? "",
            renewsAt: date(json["renews_at"]),
            endsAt: date(json["ends_at"]),
            team: team.map { EntitlementLicense.Team(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "") }
        )
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { try? RFC3339DateTranscoder().decode($0) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
