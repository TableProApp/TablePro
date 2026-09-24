//
//  MSSQLFreeTDSConfigTests.swift
//  TableProTests
//

import Foundation
import TableProMSSQLCore
import TableProPluginKit
import Testing

@Suite("MSSQL FreeTDS config")
struct MSSQLFreeTDSConfigTests {
    private func entry(
        host: String = "db.example.com",
        port: Int = 1_433,
        mode: SSLMode,
        caCertificatePath: String? = nil
    ) throws -> MSSQLFreeTDSServerEntry {
        try MSSQLFreeTDSServerEntry(
            host: host,
            port: port,
            encryption: MSSQLSSLMapping.encryptionLevel(for: mode),
            verification: MSSQLSSLMapping.certificateVerification(for: mode),
            caCertificatePath: caCertificatePath
        )
    }

    private func lines(_ entry: MSSQLFreeTDSServerEntry) -> [String] {
        entry.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @Test("Every SSL mode maps to the verification it advertises")
    func modeMapping() {
        #expect(MSSQLSSLMapping.certificateVerification(for: .disabled) == .none)
        #expect(MSSQLSSLMapping.certificateVerification(for: .preferred) == .none)
        #expect(MSSQLSSLMapping.certificateVerification(for: .required) == .none)
        #expect(MSSQLSSLMapping.certificateVerification(for: .verifyCa) == .chain)
        #expect(MSSQLSSLMapping.certificateVerification(for: .verifyIdentity) == .chainAndHostname)
    }

    @Test("Every SSL mode writes an entry, and each carries the level its mode maps to")
    func everyModeCarriesItsLevel() throws {
        for mode in SSLMode.allCases {
            let level = MSSQLSSLMapping.encryptionLevel(for: mode).rawValue
            #expect(lines(try entry(mode: mode)).contains("encryption = \(level)"), "\(mode)")
        }
        #expect(lines(try entry(mode: .required)).contains("encryption = require"))
    }

    @Test("Each level is written as libtds spells it")
    func levelSpelling() throws {
        let spellings: [(level: MSSQLEncryptionLevel, spelling: String)] = [
            (.request, "request"), (.require, "require")
        ]
        for (level, spelling) in spellings {
            let server = try MSSQLFreeTDSServerEntry(
                host: "db", port: 1_433, encryption: level, verification: .none, caCertificatePath: nil
            )
            #expect(lines(server).contains("encryption = \(spelling)"), "\(level)")
        }
    }

    @Test("The entry is named after the host, so the login packet carries the host as its server name")
    func namedAfterTheHost() throws {
        let server = try entry(host: "myserver.database.windows.net", port: 1_433, mode: .required)

        #expect(server.name == "myserver.database.windows.net")
        #expect(lines(server).prefix(4) == [
            "[myserver.database.windows.net]",
            "host = myserver.database.windows.net",
            "port = 1433",
            "tds version = 7.4"
        ])
    }

    @Test("An IP address is named with its port, so connects to other ports on it, every tunnel among them, never share a name")
    func addressNamedWithItsPort() throws {
        let cases: [(host: String, port: Int, name: String, dialled: String)] = [
            ("127.0.0.1", 54_321, "127.0.0.1,54321", "127.0.0.1"),
            ("10.0.0.5", 1_433, "10.0.0.5,1433", "10.0.0.5"),
            ("::1", 1_433, "::1,1433", "::1"),
            ("[::1]", 1_433, "::1,1433", "::1"),
            ("fe80::1%en0", 14_330, "fe80::1%en0,14330", "fe80::1%en0")
        ]
        for (host, port, name, dialled) in cases {
            let server = try entry(host: host, port: port, mode: .required)
            #expect(server.name == name, "\(host)")
            #expect(lines(server).prefix(3) == ["[\(name)]", "host = \(dialled)", "port = \(port)"], "\(host)")
        }
    }

    @Test("A host name in brackets is read without them, as libtds reads one")
    func bracketsAroundAHostAreDropped() throws {
        let server = try entry(host: "[db.example.com]", mode: .required)

        #expect(server.name == "db.example.com")
        #expect(lines(server).prefix(2) == ["[db.example.com]", "host = db.example.com"])
    }

    @Test("Every entry states the authority, the hostname check and the service principal, so a section named global cannot lend its own")
    func everyEntryIsSelfContained() throws {
        for mode in SSLMode.allCases {
            let options = lines(try entry(mode: mode)).dropFirst().map {
                $0.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            }
            #expect(options == [
                "host", "port", "tds version", "encryption", "ca file", "check certificate hostname", "spn"
            ], "\(mode)")
        }
    }

    @Test("Windows Authentication writes its service principal into the entry, past the 128 bytes a login field takes")
    func servicePrincipalIsWritten() throws {
        let host = "sql-prod-availability-group-listener-001.finance.emea.corp.contoso-international.com"
        let principal = "MSSQLSvc/\(host):1433@CORP.CONTOSO-INTERNATIONAL.COM"
        let options = MSSQLConnectionOptions(
            host: host,
            user: "",
            password: "",
            database: "app",
            authMethod: .windows,
            kerberosServicePrincipal: principal
        )

        let server = try MSSQLFreeTDSServerEntry(options: options)

        #expect(principal.utf8.count > 128)
        #expect(server.servicePrincipal == principal)
        #expect(lines(server).last == "spn = \(principal)")
    }

    @Test("A service principal is written only for Windows Authentication")
    func servicePrincipalNeedsWindowsAuthentication() throws {
        let options = MSSQLConnectionOptions(
            host: "db.example.com",
            user: "sa",
            password: "secret",
            database: "app",
            kerberosServicePrincipal: "MSSQLSvc/db.example.com:1433@EXAMPLE.COM"
        )

        let server = try MSSQLFreeTDSServerEntry(options: options)

        #expect(server.servicePrincipal == nil)
        #expect(lines(server).last == "spn =")
    }

    @Test("A service principal libtds would cut short or reshape is refused", arguments: [
        "MSSQLSvc/" + String(repeating: "h", count: 240) + ":1433@EXAMPLE.COM",
        "MSSQLSvc/db.example.com:1433@EXAMPLE;COM",
        "MSSQLSvc/db.example.com:1433@EXAMPLE#COM",
        "MSSQLSvc/db.example.com:1433\n\tencryption = off"
    ])
    func unreadableServicePrincipals(principal: String) {
        #expect(throws: MSSQLFreeTDSConfigError.unreadableServicePrincipal) {
            try MSSQLFreeTDSServerEntry(
                host: "db.example.com",
                port: 1_433,
                encryption: .require,
                verification: .none,
                caCertificatePath: nil,
                servicePrincipal: principal
            )
        }
    }

    @Test("Verify CA pins an authority and turns off the hostname check libtds makes by default")
    func verifyCaConfiguration() throws {
        let text = lines(try entry(mode: .verifyCa))

        #expect(text.contains("encryption = require"))
        #expect(text.contains("ca file = \(MSSQLFreeTDSConfig.systemTrustStorePath)"))
        #expect(text.contains("check certificate hostname = no"))
    }

    @Test("Verify Identity also checks the hostname")
    func verifyIdentityConfiguration() throws {
        let text = lines(try entry(mode: .verifyIdentity))

        #expect(text.contains("ca file = \(MSSQLFreeTDSConfig.systemTrustStorePath)"))
        #expect(text.contains("check certificate hostname = yes"))
    }

    @Test("A user supplied authority wins over the system trust store")
    func userSuppliedAuthority() throws {
        let text = lines(try entry(mode: .verifyCa, caCertificatePath: "/Users/me/My Certs/corp-ca.pem"))

        #expect(text.contains("ca file = /Users/me/My Certs/corp-ca.pem"))
        #expect(!text.contains("ca file = \(MSSQLFreeTDSConfig.systemTrustStorePath)"))
    }

    @Test("A blank authority path falls back to the system trust store")
    func blankAuthorityFallsBack() {
        #expect(MSSQLFreeTDSConfig.authorityPath(userSupplied: nil) == MSSQLFreeTDSConfig.systemTrustStorePath)
        #expect(MSSQLFreeTDSConfig.authorityPath(userSupplied: "   ") == MSSQLFreeTDSConfig.systemTrustStorePath)
        #expect(MSSQLFreeTDSConfig.authorityPath(userSupplied: "/tmp/ca.pem") == "/tmp/ca.pem")
    }

    @Test("A non-verifying mode names no authority and checks no hostname, even when a path is set")
    func nonVerifyingConfiguration() throws {
        for mode in [SSLMode.disabled, .preferred, .required] {
            let text = lines(try entry(mode: mode, caCertificatePath: "/tmp/ca.pem"))
            #expect(text.contains("ca file ="), "\(mode)")
            #expect(text.contains("check certificate hostname = no"), "\(mode)")
        }
    }

    @Test("The entry for a connection carries its level, its checks and its authority")
    func entryFromConnectionOptions() throws {
        var options = MSSQLConnectionOptions(
            host: "db.example.com",
            port: 14_330,
            user: "sa",
            password: "secret",
            database: "app",
            encryptionLevel: MSSQLSSLMapping.encryptionLevel(for: .verifyIdentity)
        )
        options.certificateVerification = MSSQLSSLMapping.certificateVerification(for: .verifyIdentity)
        options.caCertificatePath = "/certs/corp.pem"

        let text = lines(try MSSQLFreeTDSServerEntry(options: options))

        #expect(text == [
            "[db.example.com]",
            "host = db.example.com",
            "port = 14330",
            "tds version = 7.4",
            "encryption = require",
            "ca file = /certs/corp.pem",
            "check certificate hostname = yes",
            "spn ="
        ])
    }

    @Test("A connection built without a level asks for request, never off")
    func defaultLevel() {
        let options = MSSQLConnectionOptions(host: "db", user: "sa", password: "secret", database: "app")
        #expect(options.encryptionLevel == .request)
    }

    @Test("A host that would read back as something else is refused", arguments: [
        "",
        "db.example.com\n\tencryption = off",
        "db.example.com\r",
        "db example.com",
        "[db.example.com",
        "db.example.com]",
        "[]",
        "[[::1]]",
        "db=example.com",
        "db.example.com;comment",
        "db.example.com#comment",
        String(repeating: "a", count: 250)
    ])
    func unreadableHosts(host: String) {
        #expect(throws: MSSQLFreeTDSConfigError.unreadableHost) {
            try entry(host: host, mode: .required)
        }
    }

    @Test("Host names are written as given", arguments: [
        "localhost", "sql-01.corp.example.com", "MyServer", "myserver.database.windows.net"
    ])
    func readableHosts(host: String) throws {
        #expect(try entry(host: host, mode: .required).name == host)
    }

    @Test("A port outside 1 to 65535 is refused", arguments: [0, -1, 65_536])
    func invalidPorts(port: Int) {
        #expect(throws: MSSQLFreeTDSConfigError.invalidPort(port)) {
            try entry(port: port, mode: .required)
        }
    }

    @Test("An authority path libtds would cut short or reshape is refused", arguments: [
        "/certs/ca;old.pem",
        "/certs/#1.pem",
        "/certs/ca.pem ",
        "/certs/two  spaces.pem",
        "/certs/ca\n\tcheck certificate hostname = no",
        "/" + String(repeating: "c", count: 250)
    ])
    func unreadableAuthorityPaths(path: String) {
        #expect(throws: MSSQLFreeTDSConfigError.unreadableAuthorityPath) {
            try entry(mode: .verifyCa, caCertificatePath: path)
        }
    }

    @Test("The system trust store is present on this machine")
    func systemTrustStoreExists() {
        #expect(FileManager.default.fileExists(atPath: MSSQLFreeTDSConfig.systemTrustStorePath))
    }
}
