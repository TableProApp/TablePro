//
//  CompareSyncRunRegistry.swift
//  TablePro
//
//  Tracks sessions that are mid-apply so closing the window or quitting the app
//  can warn before a half-applied script is abandoned.
//

import Foundation

@MainActor
internal final class CompareSyncRunRegistry {
    internal static let shared = CompareSyncRunRegistry()

    private var applyingTargets: [ObjectIdentifier: String] = [:]

    private init() {}

    internal func markApplying(_ session: CompareSyncSession, target: String) {
        applyingTargets[ObjectIdentifier(session)] = target
    }

    internal func clear(_ session: CompareSyncSession) {
        applyingTargets.removeValue(forKey: ObjectIdentifier(session))
    }

    internal var isApplying: Bool {
        !applyingTargets.isEmpty
    }

    internal var applyingTargetNames: [String] {
        applyingTargets.values.sorted()
    }
}
