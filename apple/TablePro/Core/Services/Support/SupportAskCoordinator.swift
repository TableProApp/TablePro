//
//  SupportAskCoordinator.swift
//  TablePro
//

import AppKit
import Combine
import os

/// Counts days of use and puts the license ask on the window in use when `SupportAskSchedule`
/// says it is due and the moment is quiet.
///
/// It looks again whenever a window becomes key, the app becomes active, or the launch quiet
/// period ends, rather than polling: one of those happens soon after any moment the ask could use.
@MainActor
internal final class SupportAskCoordinator {
    struct Environment {
        var hasLicense: () -> Bool
        var isQueryRunning: () -> Bool
        var keyWindow: () -> NSWindow?
        var isModalSessionRunning: () -> Bool
        var openPricing: (URL) -> Void
        var reportShown: () -> Void
        var reportAnswer: (SupportAskAnswer) -> Void
        var now: () -> Date
    }

    enum Keys {
        static let lastAskedAt = "com.TablePro.support.lastAskedAt"
        static let lastAnswer = "com.TablePro.support.lastAnswer"
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "SupportAsk")

    private let counter: UsageDayCounter
    private let defaults: UserDefaults
    private let presenter: any SupportAskPresenting
    private let environment: Environment
    private let calendar: Calendar
    private let clock: any Clock<Duration>

    private var launchedAt: Date?
    private var subscriptions: Set<AnyCancellable> = []
    private var quietPeriodTask: Task<Void, Never>?

    init(
        counter: UsageDayCounter,
        defaults: UserDefaults,
        presenter: any SupportAskPresenting,
        environment: Environment,
        calendar: Calendar = .autoupdatingCurrent,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.counter = counter
        self.defaults = defaults
        self.presenter = presenter
        self.environment = environment
        self.calendar = calendar
        self.clock = clock
    }

    func start() {
        guard launchedAt == nil else { return }
        launchedAt = environment.now()
        counter.recordUse(at: environment.now())

        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.appBecameActive() }
            .store(in: &subscriptions)
        // Posted when the date rolls over while the app runs, from whichever thread noticed.
        center.publisher(for: .NSCalendarDayChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.dayChanged() }
            .store(in: &subscriptions)
        center.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in self?.askIfDue() }
            .store(in: &subscriptions)

        quietPeriodTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: .seconds(SupportAskSchedule.launchQuietPeriod))
            } catch {
                return
            }
            self?.askIfDue()
        }
    }

    var schedule: SupportAskSchedule {
        SupportAskSchedule(
            usageDays: counter.days,
            hasLicense: environment.hasLicense(),
            lastAskedAt: defaults.object(forKey: Keys.lastAskedAt) as? Date,
            lastAnswer: defaults.string(forKey: Keys.lastAnswer).flatMap(SupportAskAnswer.init(rawValue:))
        )
    }

    /// Presents the ask when everything allows it. Each check is cheap, and the first that fails
    /// ends the look.
    func askIfDue() {
        guard let launchedAt, !presenter.isPresenting else { return }
        let now = environment.now()
        guard schedule.isDue(at: now, calendar: calendar) else { return }
        guard SupportAskSchedule.isQuietMoment(
            launchedAt: launchedAt,
            now: now,
            isQueryRunning: environment.isQueryRunning()
        ) else { return }
        guard !environment.isModalSessionRunning(),
              let window = environment.keyWindow(),
              Self.canHostAsk(window) else { return }

        let presented = presenter.present(usageDays: counter.days, on: window) { [weak self] answer in
            self?.record(answer)
        }
        guard presented else { return }
        // Recorded on showing rather than on answering, so quitting with the sheet open still
        // counts as an ask and the next launch does not repeat it.
        defaults.set(now, forKey: Keys.lastAskedAt)
        defaults.removeObject(forKey: Keys.lastAnswer)
        environment.reportShown()
        Self.logger.info("Showed the license ask after \(self.counter.days, privacy: .public) days of use")
    }

    /// Only a window someone works in carries the ask: a connection, a data file or the welcome
    /// window. Settings, the Support window and other utility windows never do.
    static func canHostAsk(_ window: NSWindow) -> Bool {
        let identifier = window.identifier?.rawValue
        let isWorkWindow = ConnectionWindowIdentity.isPrimaryWindow(identifier)
            || ConnectionWindowIdentity.isDataFileWindow(identifier)
            || ConnectionWindowIdentity.isWelcomeWindow(identifier)
        return isWorkWindow
            && window.isVisible
            && !window.isMiniaturized
            && window.attachedSheet == nil
            && window.sheetParent == nil
    }

    private func record(_ answer: SupportAskAnswer) {
        defaults.set(answer.rawValue, forKey: Keys.lastAnswer)
        environment.reportAnswer(answer)
        if answer == .buy {
            environment.openPricing(SupportLinks.pricing(.ask))
        }
    }

    private func appBecameActive() {
        counter.recordUse(at: environment.now())
        askIfDue()
    }

    private func dayChanged() {
        guard NSApp.isActive else { return }
        counter.recordUse(at: environment.now())
    }
}

extension SupportAskCoordinator {
    static let shared = SupportAskCoordinator(
        counter: .shared,
        defaults: AppStorageEnvironment.shared.defaults,
        presenter: SupportAskSheetPresenter(),
        environment: Environment(
            hasLicense: { FeatureAccess.shared.supportAudience == .supporter },
            isQueryRunning: { MainContentCoordinator.isAnyQueryRunning },
            keyWindow: { NSApp.keyWindow },
            isModalSessionRunning: { NSApp.modalWindow != nil },
            openPricing: { url in
                Telemetry.shared.upgradeClicked(from: .ask)
                NSWorkspace.shared.open(url)
            },
            reportShown: { Telemetry.shared.supportAskShown() },
            reportAnswer: { Telemetry.shared.supportAskAnswered($0) },
            now: { Date() }
        )
    )
}
