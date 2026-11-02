import Foundation
import SwiftUI
@testable import TableProMobile
import Testing

@MainActor
struct AppLockStateTests {
    private let defaults: UserDefaults
    private let backgroundedAt = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.AppLockState.\(UUID().uuidString)"))
        defaults.set(true, forKey: AppLockState.lockEnabledKey)
        defaults.set(AppLockState.AutoLockTimeout.fiveMinutes.rawValue, forKey: AppLockState.lockTimeoutKey)
    }

    @Test("a cold launch with Require Face ID on starts locked")
    func coldLaunchIsLocked() {
        let lock = AppLockState(auth: StubDeviceOwnerAuthenticator(answer: false), defaults: defaults)

        #expect(lock.isLocked)
        #expect(lock.evaluateLock())
    }

    @Test("a Shortcut past the Auto-Lock time finds TablePro locked with no scene becoming active")
    func idleTimeoutLocksOnDemand() async {
        var clock = backgroundedAt
        let lock = AppLockState(auth: StubDeviceOwnerAuthenticator(answer: true), defaults: defaults, now: { clock })
        #expect(await lock.unlock())
        lock.handleScenePhase(.background)

        clock = backgroundedAt.addingTimeInterval(300)

        #expect(lock.evaluateLock())
        #expect(lock.isLocked)
    }

    @Test("inside the Auto-Lock time TablePro stays open, and the time keeps counting")
    func idleWindowStaysOpenThenLocks() async {
        var clock = backgroundedAt
        let lock = AppLockState(auth: StubDeviceOwnerAuthenticator(answer: true), defaults: defaults, now: { clock })
        #expect(await lock.unlock())
        lock.handleScenePhase(.background)

        clock = backgroundedAt.addingTimeInterval(299)
        #expect(!lock.evaluateLock())

        clock = backgroundedAt.addingTimeInterval(300)
        #expect(lock.evaluateLock())
    }

    @Test("coming back to TablePro inside the Auto-Lock time stops the count")
    func returningInsideWindowKeepsItOpen() async {
        var clock = backgroundedAt
        let lock = AppLockState(auth: StubDeviceOwnerAuthenticator(answer: true), defaults: defaults, now: { clock })
        #expect(await lock.unlock())
        lock.handleScenePhase(.background)

        clock = backgroundedAt.addingTimeInterval(10)
        lock.handleScenePhase(.active)
        clock = backgroundedAt.addingTimeInterval(3_600)

        #expect(!lock.evaluateLock())
    }

    @Test("with Require Face ID off nothing locks")
    func lockOffNeverLocks() {
        defaults.set(false, forKey: AppLockState.lockEnabledKey)
        var clock = backgroundedAt
        let lock = AppLockState(auth: StubDeviceOwnerAuthenticator(answer: false), defaults: defaults, now: { clock })
        #expect(!lock.isLocked)

        lock.handleScenePhase(.background)
        clock = backgroundedAt.addingTimeInterval(3_600)

        #expect(!lock.evaluateLock())
        #expect(!lock.isLocked)
    }
}
