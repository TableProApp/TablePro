import Foundation
import os

// Usage data for PostHog (clients.md, iOS), sent only once the user chooses Share Usage Data. A build without a project
// key never makes a client, and while the setting is off a client made earlier gets no call but optOut().
@MainActor
final class Telemetry {
    static let shared = Telemetry(
        projectKey: PostHogTelemetryClient.projectKey(from: Bundle.main.object(forInfoDictionaryKey: "PostHogProjectKey")),
        defaults: .standard,
        makeClient: { PostHogTelemetryClient(projectKey: $0) }
    )

    // The app reconnects on activation, so app_opened waits for the connections to be open again.
    static let appOpenedDelay: Duration = .seconds(10)
    static let appOpenedCheckInterval: Duration = .seconds(60 * 60)

    enum Keys {
        static let appOpenedAt = "com.TablePro.telemetry.appOpenedAt"
        // The heartbeat's write-once dates, kept so an updated device does not report its first use again.
        static let connectionAttemptedAt = "com.TablePro.analytics.connectionAttemptedAt"
        static let connectionSucceededAt = "com.TablePro.analytics.connectionSucceededAt"
        static let firstQueryExecutedAt = "com.TablePro.analytics.firstQueryExecutedAt"
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "Telemetry")

    private let projectKey: String?
    private let defaults: UserDefaults
    private let makeClient: (String) -> any TelemetryClient
    private let clock: any Clock<Duration>
    private let now: () -> Date
    private let calendar: Calendar

    private var client: (any TelemetryClient)?
    private var isStarted = false
    private var isEnabled = false
    private var isActive = false
    private var openConnectionTypes: () -> [String] = { [] }
    private var appOpenedTask: Task<Void, Never>?

    init(
        projectKey: String?,
        defaults: UserDefaults,
        makeClient: @escaping (String) -> any TelemetryClient,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.projectKey = PostHogTelemetryClient.projectKey(from: projectKey)
        self.defaults = defaults
        self.makeClient = makeClient
        self.clock = clock
        self.now = now
        self.calendar = calendar
    }

    // openConnectionTypes gives one database type per open connection.
    func start(sharesUsageData: Bool, openConnectionTypes: @escaping () -> [String]) {
        guard !isStarted else { return }
        isStarted = true
        self.openConnectionTypes = openConnectionTypes
        guard projectKey != nil else {
            Self.logger.info("This build has no PostHog project key; usage data is off")
            return
        }
        setEnabled(sharesUsageData)
    }

    func setEnabled(_ enabled: Bool) {
        guard isStarted, let projectKey, enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            if client == nil {
                client = makeClient(projectKey)
            }
            client?.optIn()
            scheduleAppOpened()
        } else {
            cancelAppOpened()
            client?.optOut()
        }
    }

    func sceneBecameActive() {
        isActive = true
        scheduleAppOpened()
    }

    func sceneEnteredBackground() {
        isActive = false
        cancelAppOpened()
    }

    func connectionAttempted(databaseType: String) {
        captureOnce(Keys.connectionAttemptedAt, "connection_attempted", ["database_type": databaseType])
    }

    func connectionSucceeded(databaseType: String) {
        captureOnce(Keys.connectionSucceededAt, "connection_succeeded", ["database_type": databaseType])
    }

    func queryExecuted(databaseType: String) {
        captureOnce(Keys.firstQueryExecutedAt, "first_query_executed", ["database_type": databaseType])
    }

    // MARK: - Private

    // A launch in the background, such as a sync refresh, is not an app open.
    private func scheduleAppOpened() {
        guard isEnabled, client != nil, isActive else { return }
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

    private func cancelAppOpened() {
        appOpenedTask?.cancel()
        appOpenedTask = nil
    }

    private func captureAppOpenedIfDue() {
        guard isEnabled, client != nil else { return }
        let today = now()
        if let last = defaults.object(forKey: Keys.appOpenedAt) as? Date, calendar.isDate(last, inSameDayAs: today) {
            return
        }
        let types = openConnectionTypes()
        capture("app_opened", [
            "database_types": Set(types).sorted(),
            "connection_count": types.count
        ])
        defaults.set(today, forKey: Keys.appOpenedAt)
    }

    // The date is written with the setting off too, so turning it on later does not report an old first use.
    private func captureOnce(_ key: String, _ event: String, _ properties: [String: Any]) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(now(), forKey: key)
        capture(event, properties)
    }

    private func capture(_ event: String, _ properties: [String: Any] = [:]) {
        guard isEnabled, let client else { return }
        client.capture(event, properties: properties)
    }
}
