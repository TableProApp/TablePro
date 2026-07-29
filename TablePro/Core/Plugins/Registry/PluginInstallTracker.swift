//
//  PluginInstallTracker.swift
//  TablePro
//

import Foundation

@MainActor @Observable
final class PluginInstallTracker {
    static let shared = PluginInstallTracker()

    private(set) var activeInstalls: [String: InstallProgress] = [:]

    private init() {}

    func beginInstall(pluginId: String) {
        activeInstalls[pluginId] = InstallProgress(phase: .downloading(fraction: 0))
    }

    func updateProgress(pluginId: String, fraction: Double) {
        activeInstalls[pluginId]?.phase = .downloading(fraction: min(max(fraction, 0), 1))
    }

    func markInstalling(pluginId: String) {
        activeInstalls[pluginId]?.phase = .installing
    }

    func completeInstall(pluginId: String) {
        activeInstalls[pluginId]?.phase = .completed
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if case .completed = self?.activeInstalls[pluginId]?.phase {
                self?.activeInstalls.removeValue(forKey: pluginId)
            }
        }
    }

    func failInstall(pluginId: String, error: String) {
        activeInstalls[pluginId]?.phase = .failed(error)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            if case .failed = self?.activeInstalls[pluginId]?.phase {
                self?.activeInstalls.removeValue(forKey: pluginId)
            }
        }
    }

    func markStaged(pluginId: String, newVersion: String) {
        if activeInstalls[pluginId] == nil {
            activeInstalls[pluginId] = InstallProgress(phase: .stagedPendingActivation(newVersion: newVersion))
        } else {
            activeInstalls[pluginId]?.phase = .stagedPendingActivation(newVersion: newVersion)
        }
    }

    func clearInstall(pluginId: String) {
        activeInstalls.removeValue(forKey: pluginId)
    }

    func state(for pluginId: String) -> InstallProgress? {
        activeInstalls[pluginId]
    }
}

struct InstallProgress: Equatable {
    var phase: Phase

    enum Phase: Equatable {
        case downloading(fraction: Double)
        case installing
        case stagedPendingActivation(newVersion: String)
        case completed
        case failed(String)
    }
}
