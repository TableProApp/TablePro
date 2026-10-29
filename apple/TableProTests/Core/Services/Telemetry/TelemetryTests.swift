//
//  TelemetryTests.swift
//  TableProTests
//

import Combine
import Foundation
import PostHog
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
final class RecordingTelemetryClient: TelemetryClient {
    enum Call: Equatable {
        case identify(String, [String: String])
        case capture(String, [String: String])
        case reset
        case optIn
        case optOut
    }

    private(set) var calls: [Call] = []

    func identify(_ accountID: String, personProperties: [String: Any]) {
        calls.append(.identify(accountID, Self.text(personProperties)))
    }

    func capture(_ event: String, properties: [String: Any]) {
        calls.append(.capture(event, Self.text(properties)))
    }

    func reset() { calls.append(.reset) }
    func optIn() { calls.append(.optIn) }
    func optOut() { calls.append(.optOut) }

    var captured: [String] {
        calls.compactMap { call in
            if case .capture(let event, _) = call { return event }
            return nil
        }
    }

    private static func text(_ properties: [String: Any]) -> [String: String] {
        properties.mapValues { "\($0)" }
    }
}

@MainActor
final class TelemetryFixture {
    static let person = [
        "app_version": "2.0.0", "os_version": "26.1", "architecture": "arm64", "locale": "en"
    ]

    let account: AccountFixture
    let storage: EphemeralDefaults
    let clock = ManualClock()
    let sharesUsageData: CurrentValueSubject<Bool, Never>
    private(set) var clients: [RecordingTelemetryClient] = []
    var now = Date(timeIntervalSince1970: 1_793_000_000)
    private(set) var telemetry: Telemetry!

    private let projectKey: String?

    init(projectKey: String? = "phc_test", sharesUsageData: Bool = true) throws {
        account = try AccountFixture()
        storage = try EphemeralDefaults()
        self.projectKey = projectKey
        self.sharesUsageData = CurrentValueSubject(sharesUsageData)
        relaunch()
    }

    // A new Telemetry on the same defaults, the way the next launch finds them.
    func relaunch() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        telemetry = Telemetry(
            projectKey: projectKey,
            defaults: storage.defaults,
            makeClient: { [unowned self] _ in
                let client = RecordingTelemetryClient()
                clients.append(client)
                return client
            },
            environment: {
                TelemetryEnvironment(
                    appVersion: "2.0.0", osVersion: "26.1", architecture: "arm64", locale: "en",
                    databaseTypes: ["MySQL", "PostgreSQL"], connectionCount: 3
                )
            },
            clock: clock,
            now: { [unowned self] in now },
            calendar: calendar
        )
    }

    var client: RecordingTelemetryClient? { clients.last }

    func start() {
        telemetry.start(sharesUsageData: sharesUsageData.eraseToAnyPublisher(), account: account.services)
    }

    // Past the launch delay, so the first app_opened check has run.
    func passLaunchDelay() async throws {
        await clock.waitUntilSleeping()
        clock.advance(by: Telemetry.appOpenedDelay)
        try await waitUntil { self.client?.captured.contains("app_opened") == true }
    }
}

@MainActor
struct TelemetryTests {
    @Test("A build without a project key makes no PostHog client, so nothing it does is sent")
    func emptyKeySendsNothing() async throws {
        for key in [nil, "", "  "] {
            let fixture = try TelemetryFixture(projectKey: key)
            try await fixture.account.signIn()
            fixture.start()

            await fixture.account.services.signOut()
            fixture.telemetry.connectionAttempted(databaseType: "PostgreSQL")
            fixture.telemetry.queryExecuted(databaseType: "PostgreSQL")
            fixture.telemetry.featureGateShown(.resultCharts, access: .signedOut)
            fixture.telemetry.upgradeClicked(from: .licenseSettings)
            fixture.clock.advance(by: .seconds(48 * 60 * 60))

            #expect(fixture.clients.isEmpty, "key \(key ?? "nil")")
            #expect(fixture.clock.pendingSleeperCount == 0, "no app_opened schedule without a key")
        }
    }

    @Test("The Info.plist value reads as no key when empty or when the build setting was never defined")
    func projectKeyFromInfoPlist() {
        #expect(Telemetry.projectKey(from: nil) == nil)
        #expect(Telemetry.projectKey(from: "") == nil)
        #expect(Telemetry.projectKey(from: " \n") == nil)
        #expect(Telemetry.projectKey(from: "$(POSTHOG_PROJECT_KEY)") == nil)
        #expect(Telemetry.projectKey(from: 42) == nil)
        #expect(Telemetry.projectKey(from: " phc_abc ") == "phc_abc")
    }

    @Test("With Share Usage Data off no client is made, so PostHog is never contacted")
    func optedOutMakesNoClient() async throws {
        let fixture = try TelemetryFixture(sharesUsageData: false)
        fixture.start()

        try await fixture.account.signIn()
        fixture.telemetry.connectionAttempted(databaseType: "PostgreSQL")
        fixture.clock.advance(by: .seconds(48 * 60 * 60))

        #expect(fixture.clients.isEmpty)
    }

    @Test("A Mac signed in at launch identifies as its account with the four person properties")
    func signedInAtLaunchIdentifies() async throws {
        let fixture = try TelemetryFixture()
        try await fixture.account.signIn()

        fixture.start()

        #expect(fixture.client?.calls == [.optIn, .identify("acct_test", TelemetryFixture.person)])
    }

    @Test("app_opened goes once per day with the database types and connection count")
    func appOpenedOncePerDay() async throws {
        let fixture = try TelemetryFixture()
        fixture.start()
        try await fixture.passLaunchDelay()

        let client = try #require(fixture.client)
        #expect(client.calls.last == .capture("app_opened", [
            "database_types": "[\"MySQL\", \"PostgreSQL\"]", "connection_count": "3"
        ]))

        fixture.now = fixture.now.addingTimeInterval(60 * 60)
        await fixture.clock.waitUntilSleeping()
        fixture.clock.advance(by: Telemetry.appOpenedCheckInterval)
        await fixture.clock.waitUntilSleeping()
        #expect(client.captured.filter { $0 == "app_opened" }.count == 1, "same day")

        fixture.now = fixture.now.addingTimeInterval(24 * 60 * 60)
        fixture.clock.advance(by: Telemetry.appOpenedCheckInterval)
        try await waitUntil { client.captured.filter { $0 == "app_opened" }.count == 2 }
    }

    @Test("Sign-in identifies and sends signed_in; sign-out sends signed_out as the account, then resets")
    func signInThenOut() async throws {
        let fixture = try TelemetryFixture()
        fixture.start()

        try await fixture.account.signIn()
        await fixture.account.services.signOut()

        #expect(fixture.client?.calls == [
            .optIn,
            .identify("acct_test", TelemetryFixture.person),
            .capture("signed_in", ["method": "interactive"]),
            .capture("signed_out", [:]),
            .reset
        ])
    }

    @Test("A refused refresh token resets PostHog and sends nothing as the account")
    func refusedRefreshResets() async throws {
        let fixture = try TelemetryFixture()
        try await fixture.account.signIn()
        fixture.start()
        await fixture.account.server.set { $0.refusesRefresh = true }

        _ = try? await fixture.account.services.session.refreshNow()

        let client = try #require(fixture.client)
        try await waitUntil { client.calls.last == .reset }
        #expect(!client.captured.contains("signed_out"))
        #expect(!fixture.account.access.state.isSignedIn)
    }

    @Test("A device removed elsewhere resets PostHog at the next entitlement refresh")
    func revokedDeviceResets() async throws {
        let fixture = try TelemetryFixture()
        try await fixture.account.signIn()
        fixture.start()
        await fixture.account.server.set { $0.deviceRevoked = true }

        await fixture.account.services.refreshEntitlement()

        #expect(fixture.client?.calls.last == .reset)
        #expect(fixture.client?.captured.contains("signed_out") == false)
    }

    @Test("Opted out, a sign-out, a refused refresh token or a revoked device resets only at the next opt-in")
    func optedOutSignOutResetsOnOptIn() async throws {
        for cause in [AccountEvent.SignOutCause.user, .refreshRefused, .deviceRevoked] {
            let fixture = try TelemetryFixture()
            try await fixture.account.signIn()
            fixture.start()
            let client = try #require(fixture.client)
            fixture.sharesUsageData.send(false)

            switch cause {
            case .user:
                await fixture.account.services.signOut()
            case .refreshRefused:
                await fixture.account.server.set { $0.refusesRefresh = true }
                _ = try? await fixture.account.services.session.refreshNow()
                try await waitUntil { !fixture.account.access.state.isSignedIn }
            case .deviceRevoked:
                await fixture.account.server.set { $0.deviceRevoked = true }
                await fixture.account.services.refreshEntitlement()
            }

            #expect(!fixture.account.access.state.isSignedIn, "\(cause)")
            #expect(client.calls == [.optIn, .identify("acct_test", TelemetryFixture.person), .optOut], "\(cause)")

            fixture.sharesUsageData.send(true)
            #expect(Array(client.calls.dropFirst(3)) == [.optIn, .reset], "\(cause)")
            #expect(fixture.storage.defaults.string(forKey: Telemetry.Keys.identifiedAccount) == nil, "\(cause)")
        }
    }

    @Test("Turning the setting off opts out and stops identify; turning it on opts in and identifies")
    func settingStopsIdentify() async throws {
        let fixture = try TelemetryFixture()
        fixture.start()
        let client = try #require(fixture.client)

        fixture.sharesUsageData.send(false)
        try await fixture.account.signIn()
        fixture.telemetry.queryExecuted(databaseType: "PostgreSQL")
        #expect(client.calls == [.optIn, .optOut])

        fixture.sharesUsageData.send(true)
        #expect(client.calls == [.optIn, .optOut, .optIn, .identify("acct_test", TelemetryFixture.person)])
        #expect(fixture.clients.count == 1)
    }

    @Test("A sign-out while no client existed resets the identity left from before once the setting is on")
    func staleIdentityResetsOnOptIn() async throws {
        let fixture = try TelemetryFixture(sharesUsageData: false)
        fixture.storage.defaults.set("acct_old", forKey: Telemetry.Keys.identifiedAccount)
        fixture.start()

        fixture.sharesUsageData.send(true)

        #expect(fixture.client?.calls == [.optIn, .reset])
        #expect(fixture.storage.defaults.string(forKey: Telemetry.Keys.identifiedAccount) == nil)
    }

    @Test("Use License Key with another account's key resets, then identifies as that account")
    func licenseKeySwitchesAccount() async throws {
        let fixture = try TelemetryFixture()
        try await fixture.account.signIn()
        fixture.start()
        await fixture.account.server.set { $0.accountID = "acct_other" }

        _ = try await fixture.account.services.useLicenseKey(FakeAccountServer.validKey)

        #expect(Array(fixture.client?.calls.dropFirst(2) ?? []) == [
            .reset,
            .identify("acct_other", TelemetryFixture.person),
            .capture("signed_in", ["method": "license_key"])
        ])
    }

    @Test("A stored key's migration sends signed_in as a migration")
    func migrationSignsIn() async throws {
        let fixture = try TelemetryFixture()
        try fixture.account.storeLegacyLicense(key: FakeAccountServer.validKey)
        fixture.start()

        #expect(await fixture.account.services.migrateLegacyKeyIfNeeded() == .migrated)

        #expect(fixture.client?.calls == [
            .optIn,
            .identify("acct_test", TelemetryFixture.person),
            .capture("signed_in", ["method": "migration"])
        ])
    }

    @Test("First connection attempt, first success and first query go once each with their own database type, never again after the heartbeat's dates")
    func firstUseOnce() throws {
        let fixture = try TelemetryFixture()
        fixture.start()

        fixture.telemetry.connectionAttempted(databaseType: "PostgreSQL")
        fixture.telemetry.connectionAttempted(databaseType: "MySQL")
        fixture.telemetry.connectionSucceeded(databaseType: "PostgreSQL")
        fixture.telemetry.queryExecuted(databaseType: "SQL Server")
        fixture.telemetry.queryExecuted(databaseType: "PostgreSQL")

        #expect(Array(fixture.client?.calls.dropFirst() ?? []) == [
            .capture("connection_attempted", ["database_type": "PostgreSQL"]),
            .capture("connection_succeeded", ["database_type": "PostgreSQL"]),
            .capture("first_query_executed", ["database_type": "SQL Server"])
        ])

        let updated = try TelemetryFixture()
        updated.storage.defaults.set(Date(timeIntervalSince1970: 1), forKey: Telemetry.Keys.connectionAttemptedAt)
        updated.start()
        updated.telemetry.connectionAttempted(databaseType: "PostgreSQL")
        #expect(updated.client?.captured.isEmpty == true)
    }

    @Test("A query run in the editor sends first_query_executed with the type of the connection it ran on")
    func editorQueryNamesItsConnectionType() async throws {
        let fixture = try TelemetryFixture()
        fixture.start()
        var services = AppServices.live
        services.telemetry = fixture.telemetry
        let connection = TestFixtures.makeConnection(type: .mssql)
        let window = CoordinatorFixture(
            connection: connection,
            driver: MockDatabaseDriver(connection: connection),
            services: services
        )
        window.addTab(QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query))

        window.coordinator.runQuery(viewport: .firstRow)
        try await waitUntil { fixture.client?.captured.contains("first_query_executed") == true }

        #expect(Array(fixture.client?.calls.dropFirst() ?? []) == [
            .capture("first_query_executed", ["database_type": "SQL Server"])
        ])
    }

    @Test("A Mac updated after connecting sends no first_query_executed; a new Mac still sends it on a later launch")
    func firstQueryCarriedOver() throws {
        let updated = try TelemetryFixture()
        updated.storage.defaults.set(Date(timeIntervalSince1970: 1), forKey: Telemetry.Keys.connectionSucceededAt)
        updated.start()
        updated.telemetry.queryExecuted(databaseType: "PostgreSQL")
        #expect(updated.client?.captured.isEmpty == true)

        let fresh = try TelemetryFixture()
        fresh.start()
        fresh.telemetry.connectionSucceeded(databaseType: "PostgreSQL")
        fresh.relaunch()
        fresh.start()
        fresh.telemetry.queryExecuted(databaseType: "PostgreSQL")
        #expect(fresh.client?.captured == ["first_query_executed"])
    }

    @Test("feature_gate_shown goes once per feature in a launch, and upgrade_clicked names where it came from")
    func gatesAndUpgrades() throws {
        let fixture = try TelemetryFixture()
        fixture.start()

        fixture.telemetry.featureGateShown(.resultCharts, access: .signedOut)
        fixture.telemetry.featureGateShown(.resultCharts, access: .signedOut)
        fixture.telemetry.featureGateShown(.compareSync, access: .notIncluded)
        fixture.telemetry.upgradeClicked(from: .featureGate(.compareSync))

        #expect(Array(fixture.client?.calls.dropFirst() ?? []) == [
            .capture("feature_gate_shown", ["feature": "result_charts", "reason": "signed_out"]),
            .capture("feature_gate_shown", ["feature": "compare_sync", "reason": "not_included"]),
            .capture("upgrade_clicked", ["source": "app-gate-compare-sync"])
        ])
    }

    @Test("The PostHog client collects nothing on its own and sends each event as it is captured")
    func postHogConfiguration() {
        let config = PostHogTelemetryClient.configuration(projectKey: "phc_test")

        #expect(config.host.absoluteString == "https://eu.i.posthog.com")
        #expect(config.projectToken == "phc_test")
        #expect(!config.captureApplicationLifecycleEvents)
        #expect(!config.captureScreenViews)
        #expect(!config.enableSwizzling)
        #expect(!config.capturePushNotificationOpened)
        #expect(!config.preloadFeatureFlags)
        #expect(!config.sendFeatureFlagEvent)
        #expect(!config.errorTrackingConfig.autoCapture)
        #expect(config.personProfiles == .identifiedOnly)
        #expect(config.flushAt == 1)
    }
}
