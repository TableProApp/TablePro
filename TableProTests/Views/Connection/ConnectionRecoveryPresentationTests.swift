//
//  ConnectionRecoveryPresentationTests.swift
//  TableProTests
//
//  The inline failure pane is where a reporter looked for the way to their Plugins window and
//  found only Try Again, which repeats a connect that cannot succeed.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Connection recovery presentation")
@MainActor
struct ConnectionRecoveryPresentationTests {
    private static let failure = ConnectionFailureInfo(message: "The plugin is turned off.")

    @Test("The pane's button names the fix for each action")
    func primaryTitleNamesTheFix() {
        let expected: [(ConnectionRecoveryAction, String)] = [
            (.installPlugin, String(localized: "Install Plugin…")),
            (.enablePlugin(pluginId: "p"), String(localized: "Enable Plugin")),
            (.openPluginSettings(pluginId: nil), String(localized: "Open Plugin Settings")),
            (.editConnection, String(localized: "Edit Connection…"))
        ]

        for (action, title) in expected {
            let reason = ConnectionUnavailableReason.actionRequired(Self.failure, action)
            #expect(ConnectionUnavailableView.primaryActionTitle(for: reason) == title)
        }
    }

    @Test("A plain failure still offers Try Again")
    func plainFailureRetries() {
        #expect(ConnectionUnavailableView.primaryActionTitle(for: .failed(Self.failure)) == String(localized: "Try Again"))
        #expect(!ConnectionUnavailableView.offersRetry(for: .failed(Self.failure)))
    }

    @Test("Only a fix made in Settings offers a separate retry")
    func onlySettingsOffersRetry() {
        #expect(ConnectionUnavailableView.offersRetry(for: .actionRequired(Self.failure, .openPluginSettings(pluginId: nil))))
        #expect(!ConnectionUnavailableView.offersRetry(for: .actionRequired(Self.failure, .enablePlugin(pluginId: "p"))))
        #expect(!ConnectionUnavailableView.offersRetry(for: .actionRequired(Self.failure, .installPlugin)))
        #expect(!ConnectionUnavailableView.offersRetry(for: .actionRequired(Self.failure, .editConnection)))
    }

    @Test("A request to show a plugin is answered once")
    func navigationRequestIsConsumedOnce() {
        let navigation = PluginsSettingsNavigation()
        navigation.reveal(pluginId: "com.TablePro.SQLiteDriver")

        #expect(navigation.consumePendingRequest()?.pluginId == "com.TablePro.SQLiteDriver")
        #expect(navigation.consumePendingRequest() == nil)
        #expect(navigation.pendingRequest == nil)
    }

    @Test("Asking twice for the same plugin is two requests, so the list reselects it")
    func repeatedRequestsAreDistinct() {
        let navigation = PluginsSettingsNavigation()
        navigation.reveal(pluginId: "p")
        let first = navigation.consumePendingRequest()
        navigation.reveal(pluginId: "p")
        let second = navigation.consumePendingRequest()

        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)
    }
}
