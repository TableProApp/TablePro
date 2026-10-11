//
//  TunnelCommandImportTests.swift
//  TableProTests
//

import Foundation
import TableProImport
import Testing

@testable import TablePro

@MainActor
struct TunnelCommandImportTests {
    private func exportableCommand() -> ExportableTunnelCommand {
        ExportableTunnelCommand(
            method: TunnelCommandMethod.custom.rawValue,
            command: "/usr/bin/forward --listen {port}",
            executablePath: nil,
            kubernetesNamespace: nil,
            kubernetesResource: nil,
            kubernetesContext: nil,
            awsTarget: nil,
            awsProfile: nil,
            awsRegion: nil
        )
    }

    private func exportable(withCommand: Bool) -> ExportableConnection {
        ExportableConnection(
            name: "Cluster Postgres",
            host: "db.internal",
            port: 5_432,
            database: "app",
            username: "admin",
            type: "PostgreSQL",
            tunnelCommand: withCommand ? exportableCommand() : nil
        )
    }

    @Test("exporting a connection carries its tunnel command")
    func exportCarriesTheCommand() throws {
        var connection = DatabaseConnection(name: "Cluster", type: .postgresql)
        connection.tunnelCommandMode = .inline(
            TunnelCommandConfiguration(method: .kubectl, kubernetesResource: "service/pg")
        )

        let exported = try #require(ConnectionBundleExporter().portableSettings(for: connection).tunnelCommand)
        #expect(exported.method == TunnelCommandMethod.kubectl.rawValue)
        #expect(exported.kubernetesResource == "service/pg")
    }

    @Test("a confirmed command becomes the imported connection's command tunnel")
    func importKeepsConfirmedCommand() {
        let imported = DatabaseConnection(
            importing: exportable(withCommand: true),
            id: UUID(),
            groupId: nil,
            tagIds: [],
            credentialProfileId: nil,
            resolvesSSHProfile: { _ in false }
        )
        #expect(imported.isTunnelCommandEnabled)
        #expect(imported.resolvedTunnelCommandConfig?.command == "/usr/bin/forward --listen {port}")
    }

    @Test("the preview keeps the command so the confirmation can name it")
    func previewKeepsTheCommand() {
        #expect(exportable(withCommand: true).sanitizedForImport().carriesTunnelCommand)
        #expect(!exportable(withCommand: false).carriesTunnelCommand)
    }

    @Test("stripping the command leaves everything else intact")
    func strippingKeepsTheRest() {
        let stripped = exportable(withCommand: true).withoutTunnelCommand()
        #expect(stripped.tunnelCommand == nil)
        #expect(stripped.name == "Cluster Postgres")
        #expect(stripped.host == "db.internal")
        #expect(stripped.port == 5_432)
        #expect(stripped.username == "admin")
    }

    @Test("a deeplink can never deliver a tunnel command")
    func deeplinkStripsTheCommand() throws {
        var connection = DatabaseConnection(name: "Cluster", type: .postgresql)
        connection.tunnelCommandMode = .inline(
            TunnelCommandConfiguration(method: .custom, command: "/usr/bin/forward --listen {port}")
        )
        let link = try #require(ConnectionShareLink.deeplink(for: connection))
        let url = try #require(URL(string: link))

        guard case .success(.importConnection(let bundle)) = DeeplinkParser.parse(url) else {
            Issue.record("the deeplink did not parse as a connection import")
            return
        }
        let parsed = try #require(bundle.connections.first)
        #expect(!parsed.settings.carriesTunnelCommand)
    }
}
