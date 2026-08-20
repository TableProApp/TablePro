//
//  PluginInstallTrackerStagedTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("PluginInstallTracker staged phase", .serialized)
@MainActor
struct PluginInstallTrackerStagedTests {

    private let pluginId = "com.example.staged.test"

    private func cleanup() {
        PluginInstallTracker.shared.clearInstall(pluginId: pluginId)
    }

    @Test("markStaged transitions phase to stagedPendingActivation")
    func markStagedSetsPhase() {
        defer { cleanup() }
        let tracker = PluginInstallTracker.shared
        tracker.beginInstall(pluginId: pluginId)
        tracker.markStaged(pluginId: pluginId, newVersion: "1.0.23")
        let phase = tracker.state(for: pluginId)?.phase
        if case .stagedPendingActivation(let version) = phase {
            #expect(version == "1.0.23")
        } else {
            Issue.record("Expected stagedPendingActivation, got \(String(describing: phase))")
        }
    }

    @Test("markStaged creates entry even when no prior beginInstall")
    func markStagedCreatesEntry() {
        defer { cleanup() }
        let tracker = PluginInstallTracker.shared
        tracker.markStaged(pluginId: pluginId, newVersion: "2.0.0")
        let phase = tracker.state(for: pluginId)?.phase
        if case .stagedPendingActivation(let version) = phase {
            #expect(version == "2.0.0")
        } else {
            Issue.record("Expected stagedPendingActivation, got \(String(describing: phase))")
        }
    }

    @Test("clearInstall removes staged entry")
    func clearInstallRemovesStaged() {
        let tracker = PluginInstallTracker.shared
        tracker.markStaged(pluginId: pluginId, newVersion: "1.0.0")
        tracker.clearInstall(pluginId: pluginId)
        #expect(tracker.state(for: pluginId) == nil)
    }
}
