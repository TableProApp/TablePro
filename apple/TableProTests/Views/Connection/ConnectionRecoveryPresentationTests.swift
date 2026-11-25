import Foundation
@testable import TablePro
import Testing

@MainActor
struct ConnectionRecoveryPresentationTests {
    private static let failure = ConnectionFailureInfo(message: "The plugin could not be loaded.")

    @Test("The pane's button names the fix for each action")
    func primaryTitleNamesTheFix() {
        let expected: [(ConnectionRecoveryAction, String)] = [
            (.installPlugin, String(localized: "Install Plugin…")),
            (.openPluginSettings(pluginId: nil), String(localized: "Open Plugin Settings")),
            (.editConnection, String(localized: "Edit Connection…")),
            (.openLocalNetworkSettings, String(localized: "Open System Settings"))
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
        #expect(ConnectionUnavailableView.offersRetry(for: .actionRequired(Self.failure, .openLocalNetworkSettings)))
        #expect(!ConnectionUnavailableView.offersRetry(for: .actionRequired(Self.failure, .installPlugin)))
        #expect(!ConnectionUnavailableView.offersRetry(for: .actionRequired(Self.failure, .editConnection)))
    }

    @Test("A failure that names its cause heads the pane with it")
    func namedCauseIsTheHeadline() {
        let named = ConnectionFailureInfo(title: "Local Network Access Required", message: "Cannot reach 192.168.1.9.")

        #expect(
            ConnectionUnavailableView.headline(for: .actionRequired(named, .openLocalNetworkSettings), connectionName: "Prod")
                == "Local Network Access Required"
        )
        #expect(
            ConnectionUnavailableView.headline(for: .failed(Self.failure), connectionName: "Prod")
                == String(format: String(localized: "Could not connect to %@"), "Prod")
        )
    }

    @Test("Opening plugin settings asks Settings to reveal the plugin the failure names, or the first one to update")
    func openPluginSettingsRevealsThePlugin() {
        let opener = WindowOpener()
        var requests: [SettingsRequest] = []
        opener.setSettingsPresenter { requests.append($0) }
        let connection = TestFixtures.makeConnection()

        ConnectionRecoveryPerformer.perform(.openPluginSettings(pluginId: "com.TablePro.SQLiteDriver"), for: connection, opener: opener)
        ConnectionRecoveryPerformer.perform(.openPluginSettings(pluginId: nil), for: connection, opener: opener)

        #expect(requests == [.revealPlugin("com.TablePro.SQLiteDriver"), .revealPlugin(nil)])
    }

    @Test("Edit Connection opens the editor on its first issue, through the opener it was handed")
    func editConnectionOpensOnTheFirstIssue() {
        let opener = WindowOpener()
        var opened: [(ConnectionFormRequest, ConnectionEditorFacetChoice?)] = []
        opener.setConnectionFormPresenter { opened.append(($0, $1)) }
        let connection = TestFixtures.makeConnection()

        ConnectionRecoveryPerformer.perform(.editConnection, for: connection, opener: opener)

        #expect(opened.count == 1)
        #expect(opened.first?.0 == .edit(connectionId: connection.id))
        #expect(opened.first?.1 == .firstIssue)
    }
}
