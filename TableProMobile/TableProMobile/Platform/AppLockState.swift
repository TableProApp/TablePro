//
//  AppLockState.swift
//  TableProMobile
//

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
        case oneHour = 3600

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
    private let auth: BiometricAuthService

    static let lockEnabledKey = "com.TablePro.settings.lockEnabled"
    static let lockTimeoutKey = "com.TablePro.settings.lockTimeoutSeconds"

    private static let logger = Logger(subsystem: "com.TablePro", category: "AppLockState")

    init() {
        let auth = BiometricAuthService()
        self.auth = auth
        self.isLocked = Self.shouldLockOnColdLaunch(auth: auth)
    }

    static var isLockEnabled: Bool {
        UserDefaults.standard.bool(forKey: lockEnabledKey)
    }

    static var autoLockTimeout: AutoLockTimeout {
        let stored = UserDefaults.standard.object(forKey: lockTimeoutKey) as? Int ?? AutoLockTimeout.fiveMinutes.rawValue
        return AutoLockTimeout(rawValue: stored) ?? .fiveMinutes
    }

    private static func shouldLockOnColdLaunch(auth: BiometricAuthService) -> Bool {
        guard isLockEnabled else { return false }
        return auth.availability != .unavailable
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard Self.isLockEnabled, auth.availability != .unavailable else {
            isLocked = false
            return
        }

        switch phase {
        case .background:
            if lastBackgroundedAt == nil {
                lastBackgroundedAt = Date()
            }
        case .active:
            evaluateIdleLock()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func evaluateIdleLock() {
        guard let backgrounded = lastBackgroundedAt else { return }
        let elapsed = Date().timeIntervalSince(backgrounded)
        let timeout = TimeInterval(Self.autoLockTimeout.rawValue)
        if elapsed >= timeout {
            Self.logger.info("Idle timeout exceeded (\(elapsed, format: .fixed(precision: 0))s >= \(timeout, format: .fixed(precision: 0))s), locking")
            isLocked = true
        }
        lastBackgroundedAt = nil
    }

    func unlock() async -> Bool {
        let reason = String(localized: "Unlock TablePro to access your database connections.")
        let success = await auth.authenticate(reason: reason)
        if success {
            isLocked = false
            lastBackgroundedAt = nil
        }
        return success
    }

    func lockNow() {
        guard Self.isLockEnabled, auth.availability != .unavailable else { return }
        isLocked = true
    }
}
