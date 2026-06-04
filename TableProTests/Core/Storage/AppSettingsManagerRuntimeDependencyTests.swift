//
//  AppSettingsManagerRuntimeDependencyTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("AppSettingsManager Runtime Dependencies")
@MainActor
struct AppSettingsManagerRuntimeDependencyTests {
    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "AppSettingsManagerRuntimeDependencyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("MCPServerManager init does not read settings provider")
    func mcpServerManagerInitDoesNotReadSettingsProvider() {
        var settingsReadCount = 0

        let manager = MCPServerManager(mcpSettingsProvider: {
            settingsReadCount += 1
            return .default
        })

        #expect(manager.state == .stopped)
        #expect(settingsReadCount == 0)
    }

    @Test("AppSettingsManager init does not resolve runtime service providers")
    func appSettingsManagerInitDoesNotResolveRuntimeProviders() throws {
        let defaults = try makeIsolatedDefaults()
        let storage = AppSettingsStorage(userDefaults: defaults)
        let passwordSyncStateStore = PasswordSyncStateStore(userDefaults: defaults)

        var historyProviderReadCount = 0
        var mcpProviderReadCount = 0
        var copilotProviderReadCount = 0

        let manager = AppSettingsManager(
            storage: storage,
            themeEngine: .shared,
            syncTracker: .shared,
            appEvents: .shared,
            dateFormattingService: .shared,
            queryHistoryManagerProvider: {
                historyProviderReadCount += 1
                return QueryHistoryManager(historySettingsProvider: { .default })
            },
            mcpServerManagerProvider: {
                mcpProviderReadCount += 1
                return MCPServerManager(mcpSettingsProvider: { .default })
            },
            copilotServiceProvider: {
                copilotProviderReadCount += 1
                return CopilotService(aiSettingsProvider: { .default })
            },
            userDefaults: defaults,
            passwordSyncStateStore: passwordSyncStateStore
        )

        #expect(manager.ai.providers.isEmpty)
        #expect(historyProviderReadCount == 0)
        #expect(mcpProviderReadCount == 0)
        #expect(copilotProviderReadCount == 0)
    }
}
