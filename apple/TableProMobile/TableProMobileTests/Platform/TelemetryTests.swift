import Foundation
import PostHog
@testable import TableProMobile
import TableProTestSupport
import Testing

@MainActor
final class RecordingTelemetryClient: TelemetryClient {
    enum Call: Equatable {
        case identify(String)
        case capture(String, [String: String])
        case reset
        case optIn
        case optOut
    }

    private(set) var calls: [Call] = []

    func identify(_ accountID: String, personProperties: [String: Any]) {
        calls.append(.identify(accountID))
    }

    func capture(_ event: String, properties: [String: Any]) {
        calls.append(.capture(event, properties.mapValues { "\($0)" }))
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
}

@MainActor
final class TelemetryFixture {
    let defaults: UserDefaults
    let clock = ManualClock()
    var now = Date(timeIntervalSince1970: 1_793_000_000)
    var openConnectionTypes = ["PostgreSQL", "MySQL", "PostgreSQL"]
    private(set) var clients: [RecordingTelemetryClient] = []
    private(set) var telemetry: Telemetry!

    init(projectKey: String? = "phc_test") throws {
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.Telemetry.\(UUID().uuidString)"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        telemetry = Telemetry(
            projectKey: projectKey,
            defaults: defaults,
            makeClient: { [unowned self] _ in
                let client = RecordingTelemetryClient()
                clients.append(client)
                return client
            },
            clock: clock,
            now: { [unowned self] in now },
            calendar: calendar
        )
    }

    var client: RecordingTelemetryClient? { clients.last }

    func start(sharesUsageData: Bool) {
        telemetry.start(sharesUsageData: sharesUsageData) { [unowned self] in openConnectionTypes }
    }

    func passLaunchDelay() async throws {
        await clock.waitUntilSleeping()
        clock.advance(by: Telemetry.appOpenedDelay)
        try await waitUntil { self.client?.captured.contains("app_opened") == true }
    }

    func appOpenedCount() -> Int {
        client?.captured.filter { $0 == "app_opened" }.count ?? 0
    }
}

@MainActor
struct TelemetryTests {
    @Test("With nothing stored, usage data is on and app_opened goes once the app is in front")
    func onByDefault() async throws {
        let fixture = try TelemetryFixture()
        fixture.start(sharesUsageData: OnboardingPreferences(defaults: fixture.defaults).sharesUsageData)
        fixture.telemetry.sceneBecameActive()

        try await fixture.passLaunchDelay()

        #expect(fixture.client?.calls == [
            .optIn,
            .capture("app_opened", ["database_types": "[\"MySQL\", \"PostgreSQL\"]", "connection_count": "3"])
        ])
    }

    @Test("Usage data turned off before the update makes no client, so PostHog is never contacted")
    func storedOffMakesNoClient() async throws {
        let fixture = try TelemetryFixture()
        fixture.defaults.set(false, forKey: AppPreferences.usageDataKey)
        fixture.start(sharesUsageData: OnboardingPreferences(defaults: fixture.defaults).sharesUsageData)
        fixture.telemetry.sceneBecameActive()

        fixture.telemetry.connectionAttempted(databaseType: "PostgreSQL")
        fixture.clock.advance(by: .seconds(48 * 60 * 60))

        #expect(fixture.clients.isEmpty)
        #expect(fixture.clock.pendingSleeperCount == 0)
    }

    @Test("A build without a project key makes no client")
    func noKeySendsNothing() throws {
        for key in [nil, "", " ", "$(POSTHOG_PROJECT_KEY)"] {
            let fixture = try TelemetryFixture(projectKey: key)
            fixture.start(sharesUsageData: true)
            fixture.telemetry.sceneBecameActive()
            fixture.telemetry.setEnabled(true)

            fixture.telemetry.connectionAttempted(databaseType: "PostgreSQL")
            fixture.telemetry.queryExecuted(databaseType: "PostgreSQL")

            #expect(fixture.clients.isEmpty, "key \(key ?? "nil")")
            #expect(fixture.clock.pendingSleeperCount == 0, "key \(key ?? "nil")")
        }
    }

    @Test("Turning Share Usage Data off opts out and sends nothing more, even the next day")
    func turningOffStopsEverything() async throws {
        let fixture = try TelemetryFixture()
        fixture.start(sharesUsageData: true)
        fixture.telemetry.sceneBecameActive()
        try await fixture.passLaunchDelay()

        fixture.telemetry.setEnabled(false)
        try await waitUntil { fixture.clock.pendingSleeperCount == 0 }
        fixture.telemetry.connectionAttempted(databaseType: "PostgreSQL")
        fixture.now = fixture.now.addingTimeInterval(24 * 60 * 60)
        fixture.clock.advance(by: .seconds(48 * 60 * 60))

        let client = try #require(fixture.client)
        #expect(client.calls.last == .optOut)
        #expect(client.captured == ["app_opened"])
    }

    @Test("A first use while the setting is off is not reported once it is turned on")
    func firstUseWhileOffIsNotSentLater() throws {
        let fixture = try TelemetryFixture()
        fixture.start(sharesUsageData: false)
        fixture.telemetry.connectionAttempted(databaseType: "PostgreSQL")

        fixture.telemetry.setEnabled(true)
        fixture.telemetry.connectionAttempted(databaseType: "PostgreSQL")

        #expect(fixture.client?.calls == [.optIn])
    }

    @Test("A launch in the background, such as a sync refresh, sends no app_opened")
    func backgroundLaunchIsNotAnOpen() async throws {
        let fixture = try TelemetryFixture()
        fixture.start(sharesUsageData: true)

        #expect(fixture.client?.calls == [.optIn])
        #expect(fixture.clock.pendingSleeperCount == 0)

        fixture.telemetry.sceneBecameActive()
        try await fixture.passLaunchDelay()
    }

    @Test("Going to the background before the delay ends sends no app_opened")
    func backgroundCancelsAppOpened() async throws {
        let fixture = try TelemetryFixture()
        fixture.start(sharesUsageData: true)
        fixture.telemetry.sceneBecameActive()
        await fixture.clock.waitUntilSleeping()

        fixture.telemetry.sceneEnteredBackground()
        try await waitUntil { fixture.clock.pendingSleeperCount == 0 }
        fixture.clock.advance(by: Telemetry.appOpenedDelay)

        #expect(fixture.appOpenedCount() == 0)
    }

    @Test("app_opened goes once per local day")
    func appOpenedOncePerDay() async throws {
        let fixture = try TelemetryFixture()
        fixture.start(sharesUsageData: true)
        fixture.telemetry.sceneBecameActive()
        try await fixture.passLaunchDelay()

        fixture.now = fixture.now.addingTimeInterval(60 * 60)
        await fixture.clock.waitUntilSleeping()
        fixture.clock.advance(by: Telemetry.appOpenedCheckInterval)
        await fixture.clock.waitUntilSleeping()
        #expect(fixture.appOpenedCount() == 1, "same day")

        fixture.telemetry.sceneEnteredBackground()
        fixture.telemetry.sceneBecameActive()
        await fixture.clock.waitUntilSleeping()
        fixture.clock.advance(by: Telemetry.appOpenedDelay)
        await fixture.clock.waitUntilSleeping()
        #expect(fixture.appOpenedCount() == 1, "back in front the same day")

        fixture.now = fixture.now.addingTimeInterval(24 * 60 * 60)
        fixture.clock.advance(by: Telemetry.appOpenedCheckInterval)
        try await waitUntil { fixture.appOpenedCount() == 2 }
    }

    @Test("First connection attempt, success and query go once per install with the database type")
    func firstUseOncePerInstall() throws {
        let fixture = try TelemetryFixture()
        fixture.start(sharesUsageData: true)

        for _ in 0..<2 {
            fixture.telemetry.connectionAttempted(databaseType: "SQL Server")
            fixture.telemetry.connectionSucceeded(databaseType: "SQL Server")
            fixture.telemetry.queryExecuted(databaseType: "MySQL")
        }

        #expect(fixture.client?.calls == [
            .optIn,
            .capture("connection_attempted", ["database_type": "SQL Server"]),
            .capture("connection_succeeded", ["database_type": "SQL Server"]),
            .capture("first_query_executed", ["database_type": "MySQL"])
        ])
    }

    @Test("A device updated from the daily report keeps its first-use dates and does not send them again")
    func heartbeatDatesCarryOver() throws {
        let fixture = try TelemetryFixture()
        for key in [
            Telemetry.Keys.connectionAttemptedAt, Telemetry.Keys.connectionSucceededAt, Telemetry.Keys.firstQueryExecutedAt
        ] {
            fixture.defaults.set(Date(timeIntervalSince1970: 1_780_000_000), forKey: key)
        }
        fixture.start(sharesUsageData: true)

        fixture.telemetry.connectionAttempted(databaseType: "PostgreSQL")
        fixture.telemetry.connectionSucceeded(databaseType: "PostgreSQL")
        fixture.telemetry.queryExecuted(databaseType: "PostgreSQL")

        #expect(fixture.client?.calls == [.optIn])
    }

    #if DEBUG
    @Test("A Debug build carries no PostHog project key, so local runs and tests never make a client")
    func debugBuildHasNoProjectKey() {
        #expect(PostHogTelemetryClient.projectKey(from: Bundle.main.object(forInfoDictionaryKey: "PostHogProjectKey")) == nil)
    }
    #endif

    @Test("The PostHog client on iOS collects nothing on its own and shows nothing")
    func postHogConfiguration() {
        let config = PostHogTelemetryClient.configuration(projectKey: "phc_test")

        #expect(config.host.absoluteString == "https://eu.i.posthog.com")
        #expect(config.projectToken == "phc_test")
        #expect(!config.captureApplicationLifecycleEvents)
        #expect(!config.captureScreenViews)
        #expect(!config.enableSwizzling)
        #expect(!config.capturePushNotificationOpened)
        #expect(!config.capturePushNotificationSubscriptions)
        #expect(!config.captureElementInteractions)
        #expect(!config.rageClickConfig.enabled)
        #expect(!config.sessionReplay)
        #expect(!config.surveys)
        #expect(!config.preloadFeatureFlags)
        #expect(!config.sendFeatureFlagEvent)
        #expect(!config.errorTrackingConfig.autoCapture)
        #expect(config.personProfiles == .identifiedOnly)
        #expect(config.flushAt == 1)
        let protocols = config.urlSessionConfiguration?.protocolClasses ?? []
        #expect(protocols.first.map(ObjectIdentifier.init) == ObjectIdentifier(PostHogTransportGate.self))
    }

    @Test("While usage data is off, a request through the PostHog session fails before it reaches the network")
    func transportGateRefusesWhileOff() async throws {
        let session = try #require(PostHogTelemetryClient.configuration(projectKey: "phc_test").urlSessionConfiguration)
        let request = URLRequest(url: try #require(URL(string: "https://eu.i.posthog.com/batch")))
        let wasOpen = PostHogTransportGate.isOpen
        defer { PostHogTransportGate.isOpen = wasOpen }

        PostHogTransportGate.isOpen = false
        await #expect(throws: URLError.self) {
            _ = try await URLSession(configuration: session).data(for: request)
        }

        PostHogTransportGate.isOpen = true
        #expect(!PostHogTransportGate.canInit(with: request))
    }
}
