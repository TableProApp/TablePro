//
//  AIFeatureScope.swift
//  TableProTests
//
//  The assistant, Agent mode and every surface that depends on them are drawn only with the AI
//  feature on, which is the setting's default. A case that needs it runs inside this scope.
//

import Foundation
@testable import TablePro

@MainActor
enum AIFeatureScope {
    /// Turns the feature on for the body and puts the setting back after. A machine where it is
    /// already on, which is every fresh runner, is never written to: the setting is persisted and
    /// synced, so a case that wrote it unconditionally would touch the developer's own preferences.
    static func enabled<T>(_ body: () throws -> T) rethrows -> T {
        let previous = AppSettingsManager.shared.ai
        guard !previous.enabled else { return try body() }
        var enabled = previous
        enabled.enabled = true
        AppSettingsManager.shared.ai = enabled
        defer { AppSettingsManager.shared.ai = previous }
        return try body()
    }

    /// The same scope for a case that has to suspend, which is how it lets another main-actor task
    /// run: a synchronous spin of the run loop from inside the case does not.
    static func enabled<T>(_ body: () async throws -> T) async rethrows -> T {
        let previous = AppSettingsManager.shared.ai
        guard !previous.enabled else { return try await body() }
        var enabled = previous
        enabled.enabled = true
        AppSettingsManager.shared.ai = enabled
        defer { AppSettingsManager.shared.ai = previous }
        return try await body()
    }
}
