//
//  SSHProfileAppliedTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct SSHProfileAppliedTests {
    private func makeProfile(
        id: UUID = UUID(),
        host: String = "bastion.example.com",
        username: String = "deploy"
    ) -> SSHProfile {
        SSHProfile(
            id: id,
            name: "Bastion",
            host: host,
            port: 22,
            username: username,
            authMethod: .password
        )
    }

    private func makeLinkedConnection(
        to profile: SSHProfile,
        snapshot: SSHConfiguration
    ) -> DatabaseConnection {
        var connection = TestFixtures.makeConnection()
        connection.sshTunnelMode = .profile(id: profile.id, snapshot: snapshot)
        connection.sshConfig = snapshot
        connection.sshProfileId = profile.id
        return connection
    }

    @Test("An edited profile replaces the stale host the connection was carrying")
    func refreshesStaleSnapshot() {
        let profile = makeProfile(host: "new.example.com")
        var stale = profile.toSSHConfiguration()
        stale.host = "old.example.com"
        let connection = makeLinkedConnection(to: profile, snapshot: stale)

        let refreshed = profile.applied(to: connection)

        #expect(refreshed.resolvedSSHConfig.host == "new.example.com")
        #expect(refreshed.sshConfig.host == "new.example.com")
    }

    @Test("An edited profile replaces the stale username too")
    func refreshesStaleUsername() {
        let profile = makeProfile(username: "rotated")
        var stale = profile.toSSHConfiguration()
        stale.username = "retired"
        let connection = makeLinkedConnection(to: profile, snapshot: stale)

        #expect(profile.applied(to: connection).resolvedSSHConfig.username == "rotated")
    }

    @Test("The connection keeps the remote file fields the profile does not own")
    func preservesRemoteFileFields() {
        let profile = makeProfile(host: "new.example.com")
        var stale = profile.toSSHConfiguration()
        stale.host = "old.example.com"
        stale.remoteFilePath = "/srv/app.db"
        stale.remoteFileAccess = .onServer
        let connection = makeLinkedConnection(to: profile, snapshot: stale)

        let refreshed = profile.applied(to: connection)

        #expect(refreshed.resolvedSSHConfig.host == "new.example.com")
        #expect(refreshed.resolvedSSHConfig.remoteFilePath == "/srv/app.db")
        #expect(refreshed.resolvedSSHConfig.remoteFileAccess == .onServer)
    }

    @Test("A connection linked to a different profile is left alone")
    func ignoresOtherProfiles() {
        let linked = makeProfile()
        let other = makeProfile(host: "unrelated.example.com")
        let connection = makeLinkedConnection(to: linked, snapshot: linked.toSSHConfiguration())

        #expect(other.applied(to: connection) == connection)
    }

    @Test("An inline tunnel is left alone")
    func ignoresInlineTunnel() {
        let profile = makeProfile()
        var connection = TestFixtures.makeConnection()
        var inline = SSHConfiguration()
        inline.enabled = true
        inline.host = "direct.example.com"
        connection.sshTunnelMode = .inline(inline)

        #expect(profile.applied(to: connection) == connection)
    }

    @Test("A connection already carrying the profile's values is returned unchanged")
    func noOpWhenAlreadyCurrent() {
        let profile = makeProfile()
        let connection = makeLinkedConnection(to: profile, snapshot: profile.toSSHConfiguration())

        #expect(profile.applied(to: connection) == connection)
    }
}
