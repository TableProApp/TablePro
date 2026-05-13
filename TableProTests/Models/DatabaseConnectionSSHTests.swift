//
//  DatabaseConnectionSSHTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("DatabaseConnection effectiveSSHConfig")
struct DatabaseConnectionSSHTests {
    @Test("No profile and no sshProfileId returns inline sshConfig")
    func inlineSSHConfigWithoutProfile() {
        var conn = TestFixtures.makeConnection()
        conn.sshConfig = SSHConfiguration()
        conn.sshConfig.enabled = true
        conn.sshConfig.host = "inline-host.example.com"
        conn.sshConfig.port = 2_222
        conn.sshConfig.username = "inline-user"
        conn.sshProfileId = nil

        let result = conn.effectiveSSHConfig(profile: nil)

        #expect(result.host == "inline-host.example.com")
        #expect(result.port == 2_222)
        #expect(result.username == "inline-user")
        #expect(result.enabled == true)
    }

    @Test("Profile provided and sshProfileId set returns profile config")
    func profileOverridesInlineConfig() {
        let profileId = UUID()
        var conn = TestFixtures.makeConnection()
        conn.sshConfig = SSHConfiguration()
        conn.sshConfig.enabled = true
        conn.sshConfig.host = "inline-host.example.com"
        conn.sshConfig.username = "inline-user"
        conn.sshProfileId = profileId

        let profile = SSHProfile(
            id: profileId,
            name: "Production SSH",
            host: "profile-host.example.com",
            port: 2_200,
            username: "profile-user",
            authMethod: .privateKey,
            privateKeyPath: "~/.ssh/id_ed25519"
        )

        let result = conn.effectiveSSHConfig(profile: profile)

        #expect(result.host == "profile-host.example.com")
        #expect(result.port == 2_200)
        #expect(result.username == "profile-user")
        #expect(result.authMethod == .privateKey)
        #expect(result.privateKeyPath == "~/.ssh/id_ed25519")
    }

    @Test("sshProfileId set but profile nil falls back to inline config")
    func deletedProfileFallsBackToInline() {
        var conn = TestFixtures.makeConnection()
        conn.sshConfig = SSHConfiguration()
        conn.sshConfig.enabled = true
        conn.sshConfig.host = "fallback-host.example.com"
        conn.sshConfig.username = "fallback-user"
        conn.sshProfileId = UUID()

        let result = conn.effectiveSSHConfig(profile: nil)

        #expect(result.host == "fallback-host.example.com")
        #expect(result.username == "fallback-user")
    }

    @Test("sshProfileId nil ignores provided profile and returns inline config")
    func noProfileIdIgnoresProfile() {
        var conn = TestFixtures.makeConnection()
        conn.sshConfig = SSHConfiguration()
        conn.sshConfig.enabled = true
        conn.sshConfig.host = "inline-host.example.com"
        conn.sshConfig.username = "inline-user"
        conn.sshProfileId = nil

        let profile = SSHProfile(
            id: UUID(),
            name: "Ignored Profile",
            host: "profile-host.example.com",
            username: "profile-user"
        )

        let result = conn.effectiveSSHConfig(profile: profile)

        #expect(result.host == "inline-host.example.com")
        #expect(result.username == "inline-user")
    }

    @Test("toSSHConfiguration sets enabled to true")
    func profileConfigHasEnabledTrue() {
        let profile = SSHProfile(
            name: "Test Profile",
            host: "ssh.example.com",
            port: 22,
            username: "testuser"
        )

        let config = profile.toSSHConfiguration()

        #expect(config.enabled == true)
        #expect(config.host == "ssh.example.com")
        #expect(config.username == "testuser")
    }
}
