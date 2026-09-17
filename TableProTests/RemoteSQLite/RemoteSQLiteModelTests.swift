//
//  RemoteSQLiteModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct RemoteSQLiteModelTests {
    private func sqliteConnection(access: RemoteFileAccess, path: String = "/srv/app.db") -> DatabaseConnection {
        var ssh = SSHConfiguration()
        ssh.enabled = true
        ssh.host = "prod-1"
        ssh.username = "deploy"
        ssh.remoteFilePath = path
        ssh.remoteFileAccess = access
        return DatabaseConnection(name: "remote", type: .sqlite, sshTunnelMode: .inline(ssh))
    }

    @Test func absentAccessDecodesAsReadOnlyCopy() throws {
        let json = Data("""
        {"enabled":true,"host":"prod-1","username":"deploy","remoteFilePath":"/srv/app.db"}
        """.utf8)
        let config = try JSONDecoder().decode(SSHConfiguration.self, from: json)
        #expect(config.remoteFileAccess == .readOnlyCopy)
    }

    @Test func accessRoundTripsThroughCoding() throws {
        var config = SSHConfiguration()
        config.enabled = true
        config.remoteFilePath = "/srv/app.db"
        config.remoteFileAccess = .onServer
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SSHConfiguration.self, from: data)
        #expect(decoded.remoteFileAccess == .onServer)
    }

    @Test func onServerResolvesToLiveSessionForSQLite() {
        let connection = sqliteConnection(access: .onServer)
        #expect(connection.opensRemoteDatabaseSession)
        #expect(!connection.opensRemoteDatabaseFile)
        #expect(connection.enabledTunnelKinds == [.remoteDatabaseSession])
        #expect(connection.activeTunnelKind == .remoteDatabaseSession)
    }

    @Test func readOnlyCopyResolvesToCopyForSQLite() {
        let connection = sqliteConnection(access: .readOnlyCopy)
        #expect(!connection.opensRemoteDatabaseSession)
        #expect(connection.opensRemoteDatabaseFile)
        #expect(connection.enabledTunnelKinds == [.remoteFile])
    }

    @Test func aFileBackedConnectionWithAPathNeverResolvesToPlainSSH() {
        // Both modes are a remote file, never a port forward, whatever the access says.
        #expect(sqliteConnection(access: .onServer).enabledTunnelKinds != [.ssh])
        #expect(sqliteConnection(access: .readOnlyCopy).enabledTunnelKinds != [.ssh])
    }

    @Test func liveSessionCarriesNoReadOnlyFloor() {
        let floor = SafeModeFloor.resolve(
            isEngineReadOnly: false,
            opensRemoteDatabaseFile: sqliteConnection(access: .onServer).opensRemoteDatabaseFile,
            managedMinimum: nil
        )
        #expect(floor == nil)
    }

    @Test func readOnlyCopyKeepsTheReadOnlyFloor() {
        let floor = SafeModeFloor.resolve(
            isEngineReadOnly: false,
            opensRemoteDatabaseFile: sqliteConnection(access: .readOnlyCopy).opensRemoteDatabaseFile,
            managedMinimum: nil
        )
        #expect(floor?.level == .readOnly)
        #expect(floor?.reason == .remoteDatabaseFile)
    }

    @Test func effectiveConnectionCarriesBackendMarkerTokenAndEndpoint() {
        let connection = sqliteConnection(access: .onServer)
        let effective = connection.openingRemoteSQLiteSession(
            host: "127.0.0.1", port: 61234, token: "deadbeef", remotePath: "/srv/app.db", field: .database
        )
        #expect(effective.host == "127.0.0.1")
        #expect(effective.port == 61234)
        #expect(effective.database == "/srv/app.db")
        #expect(effective.additionalFields[RemoteSQLiteWire.backendFieldKey] == RemoteSQLiteWire.agentBackendValue)
        #expect(effective.additionalFields[RemoteSQLiteWire.tokenFieldKey] == "deadbeef")
        #expect(!effective.resolvedSSHConfig.enabled)
    }
}
