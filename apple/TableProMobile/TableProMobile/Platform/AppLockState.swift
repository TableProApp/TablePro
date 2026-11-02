import Foundation
import Observation
import os
import SwiftUI

@MainActor @Observable
final class AppLockState {
    enum AutoLockTimeout: Int, CaseIterable, Identifiable, Sendable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900
        case oneHour = 3_600

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .immediately: String(localized: "Immediately")
            case .oneMinute: String(localized: "After 1 minute")
            case .fiveMinutes: String(localized: "After 5 minutes")
            case .fifteenMinutes: String(localized: "After 15 minutes")
            case .oneHour: String(localized: "After 1 hour")
            }
        }
    }

    private(set) var isLocked: Bool
    private var lastBackgroundedAt: Date?
    private var unlockTask: Task<Bool, Never>?
    private let auth: any DeviceOwnerAuthenticating
    private let defaults: UserDefaults
    private let now: () -> Date

    static let lockEnabledKey = "com.TablePro.settings.lockEnabled"
    static let lockTimeoutKey = "com.TablePro.settings.lockTimeoutSeconds"

    private static let logger = Logger(subsystem: "com.TablePro", category: "AppLockState")

    init(
        auth: any DeviceOwnerAuthenticating = BiometricAuthService(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.auth = auth
        self.defaults = defaults
        self.now = now
        self.isLocked = defaults.bool(forKey: Self.lockEnabledKey) && auth.availability != .unavailable
    }

    var biometry: BiometricAuthService.Availability {
        auth.availability
    }

    var isLockEnabled: Bool {
        defaults.bool(forKey: Self.lockEnabledKey)
    }

    var autoLockTimeout: AutoLockTimeout {
        let stored = defaults.object(forKey: Self.lockTimeoutKey) as? Int ?? AutoLockTimeout.fiveMinutes.rawValue
        return AutoLockTimeout(rawValue: stored) ?? .fiveMinutes
    }

    private var canLock: Bool {
        isLockEnabled && auth.availability != .unavailable
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard canLock else {
            isLocked = false
            return
        }

        switch phase {
        case .background:
            if lastBackgroundedAt == nil {
                lastBackgroundedAt = now()
            }
        case .active:
            evaluateLock()
            lastBackgroundedAt = nil
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    // Shortcuts run with no scene, so the idle timeout is evaluated when they ask.
    @discardableResult
    func evaluateLock() -> Bool {
        guard canLock else {
            isLocked = false
            return false
        }
        if !isLocked, let backgrounded = lastBackgroundedAt {
            let elapsed = now().timeIntervalSince(backgrounded)
            let timeout = TimeInterval(autoLockTimeout.rawValue)
            if elapsed >= timeout {
                Self.logger.info("Idle timeout exceeded (\(elapsed, format: .fixed(precision: 0))s >= \(timeout, format: .fixed(precision: 0))s), locking")
                isLocked = true
            }
        }
        return isLocked
    }

    func unlock() async -> Bool {
        guard isLocked else { return true }
        if let unlockTask {
            return await unlockTask.value
        }
        let reason = String(localized: "Unlock TablePro to access your database connections.")
        let task = Task { await auth.authenticate(reason: reason) }
        unlockTask = task
        let success = await task.value
        unlockTask = nil
        if success {
            isLocked = false
            lastBackgroundedAt = nil
        }
        return success
    }
}
