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
            #expect(ConnectionUnavailablePresentation.primaryActionTitle(reason: reason) == title)
        }
    }

    @Test("A plain failure still offers Try Again")
    func plainFailureRetries() {
        #expect(
            ConnectionUnavailableView.primaryActionTitle(for: .failed(Self.failure))
                == String(localized: "Try Again")
        )
        #expect(!ConnectionUnavailableView.offersRetry(for: .failed(Self.failure)))
        #expect(
            ConnectionUnavailablePresentation.primaryActionTitle(reason: .failed(Self.failure))
                == String(localized: "Try Again")
        )
        #expect(!ConnectionUnavailablePresentation.offersRetry(reason: .failed(Self.failure)))
    }

    @Test("Only a fix made in Settings offers a separate retry")
    func onlySettingsOffersRetry() {
        let settings = ConnectionUnavailableReason.actionRequired(
            Self.failure,
            .openPluginSettings(pluginId: nil)
        )
        #expect(ConnectionUnavailableView.offersRetry(for: settings))
        #expect(ConnectionUnavailablePresentation.offersRetry(reason: settings))
        #expect(!ConnectionUnavailableView.offersRetry(for: .actionRequired(Self.failure, .enablePlugin(pluginId: "p"))))
        #expect(!ConnectionUnavailableView.offersRetry(for: .actionRequired(Self.failure, .installPlugin)))
        #expect(!ConnectionUnavailableView.offersRetry(for: .actionRequired(Self.failure, .editConnection)))
        #expect(
            !ConnectionUnavailablePresentation.offersRetry(
                reason: .actionRequired(Self.failure, .enablePlugin(pluginId: "p"))
            )
        )
    }

    @Test("A recovery action and a plain failure share one headline")
    func headlineDoesNotNameTheFix() {
        let name = "Staging"
        #expect(
            ConnectionUnavailablePresentation.headline(
                reason: .actionRequired(Self.failure, .installPlugin),
                connectionName: name
            )
            == String(format: String(localized: "Could not connect to %@"), name)
        )
        #expect(
            ConnectionUnavailablePresentation.headline(reason: .failed(Self.failure), connectionName: name)
            == String(format: String(localized: "Could not connect to %@"), name)
        )
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
