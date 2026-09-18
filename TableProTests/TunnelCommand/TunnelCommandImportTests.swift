//
//  TunnelCommandImportTests.swift
//  TableProTests
//

import Foundation
import TableProImport
import Testing

@testable import TablePro

@Suite("Tunnel command import")
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
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil,
            tunnelCommand: withCommand ? exportableCommand() : nil
        )
    }

    private func preview(_ connection: ExportableConnection) -> (ConnectionImportPreview, ImportItem) {
        let item = ImportItem(connection: connection, status: .ready)
        let envelope = ConnectionExportEnvelope(
            formatVersion: 1,
            exportedAt: Date(),
            appVersion: "Tests",
            connections: [connection],
            groups: nil,
            tags: nil,
            credentials: nil
        )
        return (ConnectionImportPreview(envelope: envelope, items: [item]), item)
    }

    private func prepared(
        _ connection: ExportableConnection,
        keepTunnelCommands: Bool
    ) -> DatabaseConnection? {
        let (preview, item) = preview(connection)
        let result = ConnectionExportService.prepareImport(
            preview,
            resolutions: [item.id: .importNew],
            tagIdsByName: [:],
            groupIdsByName: [:],
            keepTunnelCommands: keepTunnelCommands
        )
        guard case .add(let connection) = result.operations.first else { return nil }
        return connection
    }

    @Test("exporting a connection carries its tunnel command")
    func exportCarriesTheCommand() throws {
        var connection = DatabaseConnection(name: "Cluster", type: .postgresql)
        connection.tunnelCommandMode = .inline(
            TunnelCommandConfiguration(method: .kubectl, kubernetesResource: "service/pg")
        )

        let envelope = ConnectionExportService.buildEnvelope(for: [connection])
        let exported = try #require(envelope.connections.first?.tunnelCommand)
        #expect(exported.method == TunnelCommandMethod.kubectl.rawValue)
        #expect(exported.kubernetesResource == "service/pg")
    }

    /// The default is the safe one, so a route that never asks the user cannot let a command in by
    /// forgetting to opt out.
    @Test("importing drops the command unless it was confirmed")
    func importDropsTheCommandByDefault() throws {
        let imported = try #require(prepared(exportable(withCommand: true), keepTunnelCommands: false))
        #expect(imported.tunnelCommandMode == .disabled)
        #expect(imported.host == "db.internal")
    }

    @Test("importing keeps the command once it was confirmed")
    func importKeepsConfirmedCommand() throws {
        let imported = try #require(prepared(exportable(withCommand: true), keepTunnelCommands: true))
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
        let link = try #require(ConnectionExportService.buildImportDeeplink(for: connection))
        let url = try #require(URL(string: link))

        guard case .success(.importConnection(let parsed)) = DeeplinkParser.parse(url) else {
            Issue.record("the deeplink did not parse as a connection import")
            return
        }
        #expect(!parsed.carriesTunnelCommand)
    }
}
