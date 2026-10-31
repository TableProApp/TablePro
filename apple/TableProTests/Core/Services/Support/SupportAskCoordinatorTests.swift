//
//  SupportAskCoordinatorTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct SupportAskCoordinatorTests {
    @MainActor
    final class RecordingPresenter: SupportAskPresenting {
        private(set) var shownDays: [Int] = []
        private var reply: ((SupportAskAnswer) -> Void)?

        var isPresenting: Bool {
            reply != nil
        }

        func present(usageDays: Int, on parent: NSWindow, answer: @escaping (SupportAskAnswer) -> Void) -> Bool {
            shownDays.append(usageDays)
            reply = answer
            return true
        }

        func choose(_ answer: SupportAskAnswer) {
            let pending = reply
            reply = nil
            pending?(answer)
        }
    }

    @MainActor
    final class Harness {
        let suite: EphemeralDefaults
        let presenter = RecordingPresenter()
        let window: NSWindow
        let launchedAt = Date(timeIntervalSince1970: 1_793_000_000)
        var now: Date
        var hasLicense = false
        var isQueryRunning = false
        private(set) var openedURLs: [URL] = []
        private(set) var coordinator: SupportAskCoordinator!

        init(daysBeforeLaunch: Int, windowIdentifier: String = WindowIdentifier.connection) throws {
            suite = try EphemeralDefaults()
            now = launchedAt
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt

            // The launch itself counts as one more day of use.
            suite.defaults.set(daysBeforeLaunch, forKey: UsageDayCounter.Keys.days)
            suite.defaults.set("2026-10-01", forKey: UsageDayCounter.Keys.lastDay)

            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
            window.orderFront(nil)

            let counter = UsageDayCounter(defaults: suite.defaults, calendar: calendar)
            coordinator = SupportAskCoordinator(
                counter: counter,
                defaults: suite.defaults,
                presenter: presenter,
                environment: .init(
                    hasLicense: { [unowned self] in hasLicense },
                    isQueryRunning: { [unowned self] in isQueryRunning },
                    keyWindow: { [unowned self] in window },
                    isModalSessionRunning: { false },
                    openPricing: { [unowned self] in openedURLs.append($0) },
                    now: { [unowned self] in now }
                ),
                calendar: calendar,
                clock: ManualClock()
            )
            coordinator.start()
        }

        func advance(days: Int, seconds: TimeInterval = 0) {
            now = now.addingTimeInterval(TimeInterval(days) * 86_400 + seconds)
        }

        func tearDown() {
            window.orderOut(nil)
        }
    }

    @Test("On the 30th day of use, past the launch quiet period, the ask shows on the window in use")
    func asksOnTheThirtiethDay() throws {
        let harness = try Harness(daysBeforeLaunch: 29)
        defer { harness.tearDown() }

        harness.advance(days: 0, seconds: 360)
        harness.coordinator.askIfDue()

        #expect(harness.presenter.shownDays == [30])
        #expect(harness.suite.defaults.object(forKey: SupportAskCoordinator.Keys.lastAskedAt) as? Date == harness.now)
    }

    @Test("The 29th day of use asks nothing")
    func waitsBeforeTheThirtiethDay() throws {
        let harness = try Harness(daysBeforeLaunch: 28)
        defer { harness.tearDown() }

        harness.advance(days: 0, seconds: 360)
        harness.coordinator.askIfDue()

        #expect(harness.presenter.shownDays.isEmpty)
    }

    @Test("Inside the launch quiet period, or while a query runs, nothing shows")
    func quietMomentsOnly() throws {
        let harness = try Harness(daysBeforeLaunch: 29)
        defer { harness.tearDown() }

        harness.advance(days: 0, seconds: 60)
        harness.coordinator.askIfDue()
        #expect(harness.presenter.shownDays.isEmpty)

        harness.advance(days: 0, seconds: 600)
        harness.isQueryRunning = true
        harness.coordinator.askIfDue()
        #expect(harness.presenter.shownDays.isEmpty)

        harness.isQueryRunning = false
        harness.coordinator.askIfDue()
        #expect(harness.presenter.shownDays == [30])
    }

    @Test("A license holds the ask however many days of use")
    func licenseHoldsIt() throws {
        let harness = try Harness(daysBeforeLaunch: 200)
        defer { harness.tearDown() }
        harness.hasLicense = true

        harness.advance(days: 0, seconds: 600)
        harness.coordinator.askIfDue()

        #expect(harness.presenter.shownDays.isEmpty)
    }

    @Test("A connection window opened after the first, whose identifier carries a suffix, carries the ask")
    func suffixedConnectionWindowHostsIt() throws {
        let harness = try Harness(daysBeforeLaunch: 29, windowIdentifier: "\(WindowIdentifier.connection)-2")
        defer { harness.tearDown() }

        harness.advance(days: 0, seconds: 600)
        harness.coordinator.askIfDue()

        #expect(harness.presenter.shownDays == [30])
    }

    @Test("Settings and other utility windows never carry the ask")
    func onlyWorkWindowsHostIt() throws {
        let harness = try Harness(daysBeforeLaunch: 29, windowIdentifier: WindowIdentifier.settings)
        defer { harness.tearDown() }

        harness.advance(days: 0, seconds: 600)
        harness.coordinator.askIfDue()

        #expect(harness.presenter.shownDays.isEmpty)
    }

    @Test("Buying opens the pricing page tagged app-ask, and the next ask waits 90 days")
    func buyOpensPricingAndWaits() throws {
        let harness = try Harness(daysBeforeLaunch: 29)
        defer { harness.tearDown() }
        harness.advance(days: 0, seconds: 600)
        harness.coordinator.askIfDue()

        harness.presenter.choose(.buy)

        let opened = try #require(harness.openedURLs.first)
        let query = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query == [URLQueryItem(name: "ref", value: "app-ask")])

        harness.advance(days: 89)
        harness.coordinator.askIfDue()
        #expect(harness.presenter.shownDays == [30])

        harness.advance(days: 1)
        harness.coordinator.askIfDue()
        #expect(harness.presenter.shownDays == [30, 30])
    }

    @Test("Personal use quiets the ask for a year")
    func personalUseWaitsAYear() throws {
        let harness = try Harness(daysBeforeLaunch: 29)
        defer { harness.tearDown() }
        harness.advance(days: 0, seconds: 600)
        harness.coordinator.askIfDue()

        harness.presenter.choose(.personal)

        harness.advance(days: 364)
        harness.coordinator.askIfDue()
        #expect(harness.presenter.shownDays == [30])
        #expect(harness.openedURLs.isEmpty)

        harness.advance(days: 1)
        harness.coordinator.askIfDue()
        #expect(harness.presenter.shownDays == [30, 30])
    }

    @Test("While the sheet is open, no second ask is attempted")
    func oneAskAtATime() throws {
        let harness = try Harness(daysBeforeLaunch: 29)
        defer { harness.tearDown() }
        harness.advance(days: 0, seconds: 600)

        harness.coordinator.askIfDue()
        harness.coordinator.askIfDue()

        #expect(harness.presenter.shownDays == [30])
    }
}
