//
//  ConnectionURLFormatterSSHProfileTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("ConnectionURLFormatter SSH Profile Resolution")
@MainActor
struct ConnectionURLFormatterSSHProfileTests {
    @Test("Inline SSH config produces URL with inline SSH user and host")
    func inlineSSHConfigInURL() {
        var conn = DatabaseConnection(
            name: "", host: "db.example.com", port: 3_306, database: "mydb",
            username: "dbuser", type: .mysql
        )
        conn.sshConfig.enabled = true
        conn.sshConfig.host = "ssh-inline.example.com"
        conn.sshConfig.port = 22
        conn.sshConfig.username = "sshuser"
        conn.sshProfileId = nil

        let url = ConnectionURLFormatter.format(conn, password: nil, sshPassword: nil)

        #expect(url.contains("ssh://"))
        #expect(url.contains("sshuser@ssh-inline.example.com"))
    }

    @Test("SSH profile overrides empty inline config in URL")
    func profileSSHConfigInURL() {
        let profileId = UUID()
        var conn = DatabaseConnection(
            name: "", host: "db.example.com", port: 3_306, database: "mydb",
            username: "dbuser", type: .mysql
        )
        conn.sshConfig = SSHConfiguration()
        conn.sshProfileId = profileId

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
    func noProfileFallbackUsesInlineConfig() {
        var conn = DatabaseConnection(
            name: "", host: "db.example.com", port: 3_306, database: "mydb",
            username: "dbuser", type: .mysql
        )
        conn.sshConfig.enabled = true
        conn.sshConfig.host = "ssh-fallback.example.com"
        conn.sshConfig.username = "fallbackuser"
        conn.sshProfileId = UUID()

        let url = ConnectionURLFormatter.format(conn, password: nil, sshPassword: nil)

        #expect(url.contains("ssh://"))
        #expect(url.contains("fallbackuser@ssh-fallback.example.com"))
    }
}
