//
//  Telemetry.swift
//  TablePro
//

import Combine
import Foundation
import os

@MainActor
internal protocol TelemetryClient: AnyObject {
    func identify(_ accountID: String, personProperties: [String: Any])
    func capture(_ event: String, properties: [String: Any])
    func reset()
    func optIn()
    func optOut()
}

internal struct TelemetryEnvironment {
    var appVersion: String
    var osVersion: String
    var architecture: String
    var locale: String
    var databaseTypes: [String]
    var connectionCount: Int

    var personProperties: [String: Any] {
        ["app_version": appVersion, "os_version": osVersion, "architecture": architecture, "locale": locale]
    }
}

// Usage data for PostHog (clients.md, macOS Telemetry). A build without a project key never makes a client,
// and while Share Usage Data is off no client is made, so the app contacts PostHog for neither.
@MainActor
internal final class Telemetry {
    static let shared = Telemetry(
        projectKey: projectKey(from: Bundle.main.object(forInfoDictionaryKey: "PostHogProjectKey")),
        defaults: AppStorageEnvironment.shared.defaults,
        makeClient: { PostHogTelemetryClient(projectKey: $0) },
        environment: { .current() }
    )

    nonisolated static let host = "https://eu.i.posthog.com"
    // Restored connections open first, so app_opened counts them.
    static let appOpenedDelay: Duration = .seconds(10)
    static let appOpenedCheckInterval: Duration = .seconds(60 * 60)

    enum Keys {
        static let appOpenedAt = "com.TablePro.telemetry.appOpenedAt"
        static let identifiedAccount = "com.TablePro.telemetry.identifiedAccount"
        // The heartbeat's write-once dates, kept so an updated Mac does not report its first use again.
        static let connectionAttemptedAt = "com.TablePro.analytics.connectionAttemptedAt"
        static let connectionSucceededAt = "com.TablePro.analytics.connectionSucceededAt"
        static let firstQueryExecutedAt = "com.TablePro.analytics.firstQueryExecutedAt"
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "Telemetry")

    private let projectKey: String?
    private let defaults: UserDefaults
    private let makeClient: (String) -> any TelemetryClient
    private let environment: () -> TelemetryEnvironment
    private let clock: any Clock<Duration>
    private let now: () -> Date
    private let calendar: Calendar

    private var client: (any TelemetryClient)?
    private var isStarted = false
    private var isEnabled = false
    private var accountID: String?
    private var identifiedThisRun: String?
    private var reportedGates: Set<String> = []
    private var appOpenedTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    init(
        projectKey: String?,
        defaults: UserDefaults,
        makeClient: @escaping (String) -> any TelemetryClient,
        environment: @escaping () -> TelemetryEnvironment,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.projectKey = Self.projectKey(from: projectKey)
        self.defaults = defaults
        self.makeClient = makeClient
        self.environment = environment
        self.clock = clock
        self.now = now
        self.calendar = calendar
    }

    // An unexpanded "$(POSTHOG_PROJECT_KEY)" means the build setting was never defined.
    nonisolated static func projectKey(from infoValue: Any?) -> String? {
        guard let value = infoValue as? String else { return nil }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty || key.hasPrefix("$(") ? nil : key
    }

    func start(
        sharesUsageData: AnyPublisher<Bool, Never>,
        account: AccountServices
    ) {
        guard !isStarted else { return }
        isStarted = true
        guard projectKey != nil else {
            Self.logger.info("This build has no PostHog project key; usage data is off")
            return
        }
        let state = account.access.state
        let stored = state.entitlement?.accountID ?? defaults.string(forKey: Keys.identifiedAccount)
        accountID = account.session.isSignedIn ? stored : nil
        account.events
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &subscriptions)
        sharesUsageData
            .removeDuplicates()
            .sink { [weak self] isEnabled in self?.setEnabled(isEnabled) }
            .store(in: &subscriptions)
    }

    private func handle(_ event: AccountEvent) {
        switch event {
        case .signedIn(let accountID, let method):
            self.accountID = accountID
            reconcileIdentity()
            capture("signed_in", ["method": method.rawValue])
        case .signedOut(.user):
            capture("signed_out")
            accountID = nil
            reconcileIdentity()
        case .signedOut:
            // The account may be deleted: an event sent as it would make its PostHog person again.
            accountID = nil
            reconcileIdentity()
        }
    }

    func connectionAttempted(databaseType: String) {
        captureOnce(Keys.connectionAttemptedAt, "connection_attempted", ["database_type": databaseType])
    }

    func connectionSucceeded(databaseType: String) {
        captureOnce(Keys.connectionSucceededAt, "connection_succeeded", ["database_type": databaseType])
    }

    func queryExecuted() {
        captureOnce(Keys.firstQueryExecutedAt, "first_query_executed", [:])
    }

    // Once per feature and launch: a gate's view appears again on every layout pass that rebuilds it.
    func featureGateShown(_ feature: ProFeature, access: ProFeatureAccess) {
        guard reportedGates.insert(feature.rawValue).inserted else { return }
        capture("feature_gate_shown", ["feature": feature.rawValue, "reason": Self.reason(for: access)])
    }

    func upgradeClicked(from referrer: SupportReferrer) {
        capture("upgrade_clicked", ["source": referrer.parameterValue])
    }

    // No properties: the count of days used stays on the Mac.
    func supportAskShown() {
        capture("support_ask_shown")
    }

    func supportAskAnswered(_ answer: SupportAskAnswer) {
        capture("support_ask_answered", ["answer": Self.value(for: answer)])
    }

    // MARK: - Private

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard let projectKey else { return }
        if enabled {
            if client == nil {
                client = makeClient(projectKey)
            }
            client?.optIn()
            reconcileIdentity()
            scheduleAppOpened()
        } else {
            appOpenedTask?.cancel()
            appOpenedTask = nil
            client?.optOut()
        }
    }

    // Opted out, a sign-out still resets; only identify waits for the setting.
    private func reconcileIdentity() {
        guard let client else { return }
        let identified = defaults.string(forKey: Keys.identifiedAccount)
        if let identified, identified != accountID {
            client.reset()
            defaults.removeObject(forKey: Keys.identifiedAccount)
            identifiedThisRun = nil
        }
        guard isEnabled, let accountID, identifiedThisRun != accountID else { return }
        client.identify(accountID, personProperties: environment().personProperties)
        defaults.set(accountID, forKey: Keys.identifiedAccount)
        identifiedThisRun = accountID
    }

    private func scheduleAppOpened() {
        appOpenedTask?.cancel()
        appOpenedTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: Self.appOpenedDelay)
                while !Task.isCancelled {
                    self?.captureAppOpenedIfDue()
                    try await clock.sleep(for: Self.appOpenedCheckInterval)
                }
            } catch {
                return
            }
        }
    }

    private func captureAppOpenedIfDue() {
        guard isEnabled, client != nil else { return }
        let today = now()
        if let last = defaults.object(forKey: Keys.appOpenedAt) as? Date, calendar.isDate(last, inSameDayAs: today) {
            return
        }
        let environment = environment()
        capture("app_opened", [
            "database_types": environment.databaseTypes,
            "connection_count": environment.connectionCount
        ])
        defaults.set(today, forKey: Keys.appOpenedAt)
    }

    private func captureOnce(_ key: String, _ event: String, _ properties: [String: Any]) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(now(), forKey: key)
        capture(event, properties)
    }

    private func capture(_ event: String, _ properties: [String: Any] = [:]) {
        guard isEnabled, let client else { return }
        client.capture(event, properties: properties)
    }

    // Not the stored raw value, which keeps the case name; events spell values in snake case.
    private static func value(for answer: SupportAskAnswer) -> String {
        switch answer {
        case .buy: "buy"
        case .personal: "personal"
        case .notNow: "not_now"
        }
    }

    private static func reason(for access: ProFeatureAccess) -> String {
        switch access {
        case .available: "available"
        case .signedOut: "signed_out"
        case .notIncluded: "not_included"
        case .expired: "expired"
        case .refreshFailed: "refresh_failed"
        }
    }
}

extension TelemetryEnvironment {
    @MainActor
    static func current() -> TelemetryEnvironment {
        let sessions = DatabaseManager.shared.activeSessions.values
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return TelemetryEnvironment(
            appVersion: Bundle.main.appVersion,
            osVersion: MachineDescription.osVersion(ProcessInfo.processInfo.operatingSystemVersion),
            architecture: architecture,
            locale: AppSettingsStorage.shared.loadGeneral().language.rawValue,
            databaseTypes: Set(sessions.map { $0.connection.type.rawValue }).sorted(),
            connectionCount: sessions.count
        )
    }
}
