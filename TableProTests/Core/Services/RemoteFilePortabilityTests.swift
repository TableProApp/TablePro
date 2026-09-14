//
//  RemoteFilePortabilityTests.swift
//  TableProTests
//

import Foundation
import TableProImport
import Testing

@testable import TablePro

/// Exporting, sharing and importing a Remote Database File connection must carry the remote path and
/// the access mode, which the export format used to drop.
@MainActor
struct RemoteFilePortabilityTests {
    private func remoteFileConnection(access: RemoteFileAccess) -> DatabaseConnection {
        var ssh = SSHConfiguration()
        ssh.enabled = true
        ssh.host = "prod-1"
        ssh.username = "deploy"
        ssh.remoteFilePath = "/srv/app.db"
        ssh.remoteFileAccess = access
        return DatabaseConnection(name: "Remote", type: .sqlite, sshConfig: ssh)
    }

    @Test("A share link carries the remote path and access mode")
    func deeplinkCarriesRemoteFile() throws {
        let link = try #require(ConnectionExportService.buildImportDeeplink(for: remoteFileConnection(access: .onServer)))
        #expect(link.contains("sshRemoteFilePath="))
        #expect(link.contains("app.db"))
        #expect(link.contains("sshRemoteFileAccess=onServer"))
    }

    @Test("The read-only copy mode is the default and is left out of the link")
    func deeplinkOmitsDefaultAccess() throws {
        let link = try #require(ConnectionExportService.buildImportDeeplink(for: remoteFileConnection(access: .readOnlyCopy)))
        #expect(link.contains("sshRemoteFilePath="))
        #expect(!link.contains("sshRemoteFileAccess="))
    }

    @Test("A rebuilt connection carries the remote path and access mode")
    func importRebuildsRemoteFileFields() {
        let exportable = ExportableConnection(
            name: "Remote", host: "", port: 0, database: "", username: "", type: "SQLite",
            sshConfig: ExportableSSHConfig(
                enabled: true, host: "prod-1", port: 22, username: "deploy",
                authMethod: "password", privateKeyPath: "", agentSocketPath: "", jumpHosts: nil,
                totpMode: nil, totpAlgorithm: nil, totpDigits: nil, totpPeriod: nil,
                remoteFilePath: "/srv/app.db", remoteFileAccess: "onServer"
            ),
            sslConfig: nil, color: nil, tagName: nil, groupName: nil,
            sshProfileId: nil, safeModeLevel: nil, aiPolicy: nil,
            additionalFields: nil, redisDatabase: nil, startupCommands: nil, localOnly: nil
        )
        let rebuilt = ConnectionExportService.buildDatabaseConnection(
            id: UUID(), from: exportable, name: "Remote", tagIdsByName: [:], groupIdsByName: [:]
        )
        #expect(rebuilt.resolvedSSHConfig.remoteFilePath == "/srv/app.db")
        #expect(rebuilt.resolvedSSHConfig.remoteFileAccess == .onServer)
    }

    @Test("A rebuilt connection without the access key defaults to the read-only copy")
    func importDefaultsAccessToCopy() {
        let exportable = ExportableConnection(
            name: "Remote", host: "", port: 0, database: "", username: "", type: "SQLite",
            sshConfig: ExportableSSHConfig(
                enabled: true, host: "prod-1", port: 22, username: "deploy",
                authMethod: "password", privateKeyPath: "", agentSocketPath: "", jumpHosts: nil,
                totpMode: nil, totpAlgorithm: nil, totpDigits: nil, totpPeriod: nil,
                remoteFilePath: "/srv/app.db", remoteFileAccess: nil
            ),
            sslConfig: nil, color: nil, tagName: nil, groupName: nil,
            sshProfileId: nil, safeModeLevel: nil, aiPolicy: nil,
            additionalFields: nil, redisDatabase: nil, startupCommands: nil, localOnly: nil
        )
        let rebuilt = ConnectionExportService.buildDatabaseConnection(
            id: UUID(), from: exportable, name: "Remote", tagIdsByName: [:], groupIdsByName: [:]
        )
        #expect(rebuilt.resolvedSSHConfig.remoteFilePath == "/srv/app.db")
        #expect(rebuilt.resolvedSSHConfig.remoteFileAccess == .readOnlyCopy)
    }
}
