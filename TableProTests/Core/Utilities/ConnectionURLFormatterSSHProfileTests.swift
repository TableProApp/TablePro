//
//  ConnectionURLFormatterSSHProfileTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("ConnectionURLFormatter SSH Profile Resolution")
@MainActor
struct ConnectionURLFormatterSSHProfileTests {
    @Test("Inline SSH config produces URL with inline SSH user and host")
    /// Driven through `sshTunnelMode`, which is what `resolvedSSHConfig` reads. Setting the legacy
    /// `sshConfig` field no longer turns a tunnel on, so these were formatting a plain mysql:// URL
    /// and asserting it contained ssh://.
    func inlineSSHConfigInURL() {
        var conn = DatabaseConnection(
            name: "", host: "db.example.com", port: 3_306, database: "mydb",
            username: "dbuser", type: .mysql
        )
        var inline = SSHConfiguration()
        inline.enabled = true
        inline.host = "ssh-inline.example.com"
        inline.port = 22
        inline.username = "sshuser"
        conn.sshTunnelMode = .inline(inline)

        let url = ConnectionURLFormatter.format(conn, password: nil, sshPassword: nil)

        #expect(url.contains("ssh://"))
        #expect(url.contains("sshuser@ssh-inline.example.com"))
    }

    @Test("SSH profile overrides empty inline config in URL")
    /// Driven through `sshTunnelMode`, which is what `resolvedSSHConfig` reads. Setting the legacy
    /// `sshConfig` field no longer turns a tunnel on, so these were formatting a plain mysql:// URL
    /// and asserting it contained ssh://.
    func profileSSHConfigInURL() {
        let profileId = UUID()
        var conn = DatabaseConnection(
            name: "", host: "db.example.com", port: 3_306, database: "mydb",
            username: "dbuser", type: .mysql
        )
        var snapshot = SSHConfiguration()
        snapshot.enabled = true
        snapshot.host = "ssh-profile.example.com"
        snapshot.port = 2_222
        snapshot.username = "profileuser"
        conn.sshTunnelMode = .profile(id: profileId, snapshot: snapshot)

        let profile = SSHProfile(
            id: profileId,
            name: "My SSH Profile",
            host: "ssh-profile.example.com",
            port: 2_222,
            username: "profileuser"
        )

        let url = ConnectionURLFormatter.format(conn, password: nil, sshPassword: nil, sshProfile: profile)

        #expect(url.contains("ssh://"))
        #expect(url.contains("profileuser@ssh-profile.example.com"))
        #expect(url.contains(":2222"))
    }

    @Test("No profile fallback produces URL with inline SSH data")
    /// Driven through `sshTunnelMode`, which is what `resolvedSSHConfig` reads. Setting the legacy
    /// `sshConfig` field no longer turns a tunnel on, so these were formatting a plain mysql:// URL
    /// and asserting it contained ssh://.
    func noProfileFallbackUsesInlineConfig() {
        var conn = DatabaseConnection(
            name: "", host: "db.example.com", port: 3_306, database: "mydb",
            username: "dbuser", type: .mysql
        )
        var inline = SSHConfiguration()
        inline.enabled = true
        inline.host = "ssh-fallback.example.com"
        inline.username = "fallbackuser"
        conn.sshTunnelMode = .inline(inline)

        let url = ConnectionURLFormatter.format(conn, password: nil, sshPassword: nil)

        #expect(url.contains("ssh://"))
        #expect(url.contains("fallbackuser@ssh-fallback.example.com"))
    }
}
