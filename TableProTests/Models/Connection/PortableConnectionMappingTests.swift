//
//  PortableConnectionMappingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import TableProPluginKit
import Testing

@MainActor
struct PortableConnectionMappingTests {
    private func settings(sslMode: String? = nil, safeModeLevel: String? = nil) -> ExportableConnection {
        var settings = ExportableConnection(
            name: "Production",
            host: "db.example.com",
            port: 5_432,
            database: "app",
            username: "admin",
            type: DatabaseType.postgresql.rawValue
        )
        settings.sslConfig = sslMode.map { ExportableSSLConfig(mode: $0) }
        settings.safeModeLevel = safeModeLevel
        return settings
    }

    private func imported(
        _ settings: ExportableConnection,
        credentialProfileId: UUID? = nil,
        storedSSHProfiles: Set<UUID> = []
    ) -> DatabaseConnection {
        DatabaseConnection(
            importing: settings,
            id: UUID(),
            groupId: nil,
            tagIds: [],
            credentialProfileId: credentialProfileId,
            resolvesSSHProfile: { storedSSHProfiles.contains($0) }
        )
    }

    // MARK: - SSL

    @Test("Every portable SSL mode maps to a Mac mode and back", arguments: PortableSSLMode.allCases)
    func portableModeRoundTrips(_ portable: PortableSSLMode) {
        #expect(SSLMode(portable).portableMode == portable)
    }

    @Test("Every Mac SSL mode maps to a portable mode and back")
    func macModeRoundTrips() {
        for mode in SSLMode.allCases {
            let roundTripped = SSLMode(mode.portableMode)
            #expect(roundTripped == mode)
        }
    }

    @Test("An iPhone file's SSL spellings import as the modes they name")
    func iOSSpellingsImport() {
        #expect(imported(settings(sslMode: "require")).sslConfig.mode == .required)
        #expect(imported(settings(sslMode: "verifyCa")).sslConfig.mode == .verifyCa)
        #expect(imported(settings(sslMode: "verifyFull")).sslConfig.mode == .verifyIdentity)
        #expect(imported(settings(sslMode: "disable")).sslConfig.mode == .disabled)
    }

    @Test("An SSL mode this build does not know imports as Required")
    func unknownSSLModeImportsAsRequired() {
        #expect(imported(settings(sslMode: "someFutureMode")).sslConfig.mode == .required)
    }

    @Test("A connection without SSL settings imports with SSL off")
    func missingSSLImportsDisabled() {
        #expect(imported(settings()).sslConfig.mode == .disabled)
    }

    @Test("Export writes the canonical SSL spelling and leaves SSL out when it is off")
    func exportWritesCanonicalSSL() throws {
        let verified = try #require(ExportableSSLConfig(portable: SSLConfiguration(mode: .verifyCa)))
        #expect(verified.mode == "Verify CA")
        #expect(ExportableSSLConfig(portable: SSLConfiguration(mode: .disabled)) == nil)
    }

    // MARK: - Safe Mode

    @Test("An iOS Confirm Writes connection imports as Alert")
    func iOSConfirmWritesImportsAsAlert() {
        #expect(imported(settings(safeModeLevel: "confirmWrites")).preferredSafeModeLevel == .alert)
    }

    @Test("An iOS Off connection and a file with no level import as Silent")
    func iOSOffImportsAsSilent() {
        #expect(imported(settings(safeModeLevel: "off")).preferredSafeModeLevel == .silent)
        #expect(imported(settings()).preferredSafeModeLevel == .silent)
    }

    @Test("A Mac level imports unchanged", arguments: SafeModeLevel.allCases)
    func macLevelImportsUnchanged(_ level: SafeModeLevel) {
        #expect(imported(settings(safeModeLevel: level.rawValue)).preferredSafeModeLevel == level)
    }

    @Test("An unrecognized level imports as Alert instead of Silent")
    func unrecognizedLevelImportsAsAlert() {
        #expect(imported(settings(safeModeLevel: "someFutureLevel")).preferredSafeModeLevel == .alert)
    }

    // MARK: - Links to local records

    @Test("A credential profile links only when the import created it")
    func credentialProfileLinksOnlyWhenCreated() {
        let created = UUID()
        #expect(imported(settings(), credentialProfileId: created).credentialMode == .profile(id: created))
        #expect(imported(settings()).credentialMode == .inline)
    }

    @Test("An SSH profile id binds only when this Mac stores that profile")
    func sshProfileBindsOnlyWhenStored() {
        let stored = UUID()
        var known = settings()
        known.sshProfileId = stored.uuidString
        var unknown = settings()
        unknown.sshProfileId = UUID().uuidString

        #expect(imported(known, storedSSHProfiles: [stored]).sshProfileId == stored)
        #expect(imported(unknown, storedSSHProfiles: [stored]).sshProfileId == nil)
    }

    // MARK: - Other fields

    @Test("An imported icon is trimmed, and a malformed one is dropped")
    func importNormalizesIcon() {
        var trimmed = settings()
        trimmed.iconName = " server.rack\n"
        var junk = settings()
        junk.iconName = "../../etc/passwd"

        #expect(imported(trimmed).iconName == "server.rack")
        #expect(imported(junk).iconName == nil)
        #expect(imported(settings()).iconName == nil)
    }

    @Test("A blank host imports as localhost")
    func blankHostImportsAsLocalhost() {
        var blank = settings()
        blank.host = "  "
        #expect(imported(blank).host == "localhost")
    }

    @Test("A carried tunnel command becomes the connection's command tunnel")
    func tunnelCommandBecomesInlineMode() {
        var carrying = settings()
        carrying.tunnelCommand = ExportableTunnelCommand(
            TunnelCommandConfiguration(method: .custom, command: "/usr/bin/forward --listen {port}")
        )

        let connection = imported(carrying)

        #expect(connection.isTunnelCommandEnabled)
        #expect(connection.resolvedTunnelCommandConfig?.command == "/usr/bin/forward --listen {port}")
    }

    @Test("SSH settings survive export and import, home paths included")
    func sshRoundTrips() throws {
        var ssh = SSHConfiguration()
        ssh.enabled = true
        ssh.host = "bastion.example.com"
        ssh.port = 2_222
        ssh.username = "deploy"
        ssh.authMethod = .privateKey
        ssh.privateKeyPath = NSHomeDirectory() + "/.ssh/id_ed25519"
        ssh.totpMode = .autoGenerate
        ssh.jumpHosts = [
            SSHJumpHost(host: "jump.example.com", port: 22, username: "ops", authMethod: .privateKey, privateKeyPath: "~/.ssh/jump")
        ]

        let exported = try #require(ExportableSSHConfig(portable: ssh))
        #expect(exported.privateKeyPath == "~/.ssh/id_ed25519")
        #expect(exported.totpAlgorithm == nil)

        let restored = SSHConfiguration(importing: exported)
        #expect(restored.host == ssh.host)
        #expect(restored.port == ssh.port)
        #expect(restored.authMethod == .privateKey)
        #expect(restored.privateKeyPath == ssh.privateKeyPath)
        #expect(restored.totpMode == .autoGenerate)
        #expect(restored.jumpHosts.first?.host == "jump.example.com")
        #expect(ExportableSSHConfig(portable: SSHConfiguration()) == nil)
    }
}
