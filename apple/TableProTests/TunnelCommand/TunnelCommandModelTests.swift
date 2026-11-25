//
//  TunnelCommandModelTests.swift
//  TableProTests
//

import Foundation
import TableProImport
import Testing

@testable import TablePro

struct TunnelCommandModelTests {
    private func kubectlConfig() -> TunnelCommandConfiguration {
        TunnelCommandConfiguration(
            method: .kubectl,
            kubernetesNamespace: "production",
            kubernetesResource: "service/postgres",
            kubernetesContext: "prod-eks"
        )
    }

    @Test("an enabled mode round-trips through Codable")
    func modeRoundTrips() throws {
        let mode = TunnelCommandMode.inline(kubectlConfig())
        let data = try JSONEncoder().encode(mode)
        #expect(try JSONDecoder().decode(TunnelCommandMode.self, from: data) == mode)
    }

    @Test("a disabled mode round-trips without a configuration")
    func disabledRoundTrips() throws {
        let data = try JSONEncoder().encode(TunnelCommandMode.disabled)
        #expect(try JSONDecoder().decode(TunnelCommandMode.self, from: data) == .disabled)
    }

    @Test("a configuration written by an older build decodes with defaults")
    func partialConfigurationDecodes() throws {
        let json = Data(#"{"method":"custom","command":"forward {port}"}"#.utf8)
        let config = try JSONDecoder().decode(TunnelCommandConfiguration.self, from: json)
        #expect(config.method == .custom)
        #expect(config.command == "forward {port}")
        #expect(config.awsTarget.isEmpty)
    }

    @Test("a connection carrying an enabled mode reports it")
    func connectionReportsMode() {
        var connection = DatabaseConnection(name: "K8s", type: .postgresql)
        #expect(!connection.isTunnelCommandEnabled)
        #expect(connection.resolvedTunnelCommandConfig == nil)

        connection.tunnelCommandMode = .inline(kubectlConfig())
        #expect(connection.isTunnelCommandEnabled)
        #expect(connection.resolvedTunnelCommandConfig == kubectlConfig())
    }

    @Test("a connection round-trips the mode through its own Codable")
    func connectionCodableRoundTrip() throws {
        var connection = DatabaseConnection(name: "K8s", type: .postgresql)
        connection.tunnelCommandMode = .inline(kubectlConfig())

        let data = try JSONEncoder().encode(connection)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(decoded.tunnelCommandMode == connection.tunnelCommandMode)
    }

    @Test("the editor's draft loads and rebuilds the mode, trimming as it goes")
    @MainActor
    func draftRoundTrip() {
        let postgres = ConnectionTypeTraits.live(for: .postgresql, pluginManager: .shared)
        var connection = DatabaseConnection(name: "K8s", type: .postgresql)
        connection.tunnelCommandMode = .inline(kubectlConfig())

        var draft = ConnectionDraft.loaded(from: connection, secrets: .none, traits: postgres)
        #expect(draft.transport == .tunnelCommand)
        #expect(ConnectionEditorEngine.edits(draft, postgres, originalTraits: nil, EditorContext()).tunnelCommandMode
            == connection.tunnelCommandMode)

        draft.tunnelCommand.config.kubernetesResource = "  service/postgres  "
        #expect(draft.tunnelCommand.trimmedConfiguration.kubernetesResource == "service/postgres")
        guard case .inline(let written) = ConnectionEditorEngine.edits(
            draft, postgres, originalTraits: nil, EditorContext()
        ).tunnelCommandMode else {
            Issue.record("Expected an inline mode")
            return
        }
        #expect(written.kubernetesResource == "service/postgres")

        draft.selectTransport(nil)
        #expect(ConnectionEditorEngine.edits(draft, postgres, originalTraits: nil, EditorContext()).tunnelCommandMode == .disabled)
    }

    @Test("the export bridge round-trips every field")
    func exportBridgeRoundTrips() {
        var config = kubectlConfig()
        config.executablePath = "/opt/homebrew/bin/kubectl"
        let exportable = ExportableTunnelCommand(config)
        #expect(TunnelCommandConfiguration(exportable) == config)
    }

    @Test("an unknown exported method decodes as a custom command")
    func unknownMethodDecodesAsCustom() {
        let exportable = ExportableTunnelCommand(
            method: "somethingNewer",
            command: "forward {port}",
            executablePath: nil,
            kubernetesNamespace: nil,
            kubernetesResource: nil,
            kubernetesContext: nil,
            awsTarget: nil,
            awsProfile: nil,
            awsRegion: nil
        )
        #expect(TunnelCommandConfiguration(exportable).method == .custom)
    }
}
