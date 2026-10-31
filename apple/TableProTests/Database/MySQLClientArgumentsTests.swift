//
//  MySQLClientArgumentsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// Every expectation here was measured against MariaDB 12.3.3 and MySQL 8.4.11 client tools, run
/// against a MariaDB server with TLS off, a MariaDB server with a self-signed certificate and a
/// MySQL server with its own.
struct MySQLClientArgumentsTests {
    private func ssl(
        _ mode: SSLMode,
        ca: String = "",
        certificate: String = "",
        key: String = ""
    ) -> SSLConfiguration {
        SSLConfiguration(
            mode: mode,
            caCertificatePath: ca,
            clientCertificatePath: certificate,
            clientKeyPath: key
        )
    }

    @Test("A restore client gets the family's command switch only from the release that has it", arguments: [
        (NativeDumpToolFlavor.mysql, "8.0.39", false), (.mysql, "8.0.40", true), (.mysql, "8.3.0", false),
        (.mysql, "8.4.2", false), (.mysql, "8.4.3", true), (.mysql, "9.0.1", false), (.mysql, "9.1.0", true),
        (.mysql, "9.5.0", true), (.mariadb, "10.5.25", false), (.mariadb, "10.6.17", false),
        (.mariadb, "10.6.18", true), (.mariadb, "10.11.8", true), (.mariadb, "11.4.1", false),
        (.mariadb, "11.4.2", true), (.mariadb, "13.0.2", true)
    ] as [(NativeDumpToolFlavor, String, Bool)])
    func restoreSafetyFollowsTheRelease(flavor: NativeDumpToolFlavor, release: String, hasSwitch: Bool) {
        let banner = flavor == .mariadb ? "mariadb from \(release)-MariaDB, client 15.2" : "mysql  Ver \(release) for macos"
        let tool = NativeDumpResolvedTool(name: "mysql", path: "/usr/bin/mysql", flavor: flavor, versionText: banner)
        let switchFlag = flavor == .mariadb ? "--sandbox" : "--skip-system-command"
        let flags = MySQLClientArguments.restoreSafety(tool: tool)
        #expect(flags == ["--binary-mode", "--local-infile=0"] + (hasSwitch ? [switchFlag] : []))
    }

    @Test("A restore client that names no release still gets binary mode and no local files")
    func restoreSafetyWithoutARelease() {
        let unnamed = NativeDumpResolvedTool(name: "mysql", path: "/usr/bin/mysql", flavor: .unidentified)
        #expect(MySQLClientArguments.restoreSafety(tool: unnamed) == ["--binary-mode", "--local-infile=0"])
    }

    @Test("MySQL's tools take --ssl-mode for every mode")
    func mysqlSpelling() throws {
        let expected: [SSLMode: String] = [
            .disabled: "--ssl-mode=DISABLED",
            .preferred: "--ssl-mode=PREFERRED",
            .required: "--ssl-mode=REQUIRED",
            .verifyCa: "--ssl-mode=VERIFY_CA",
            .verifyIdentity: "--ssl-mode=VERIFY_IDENTITY"
        ]
        for (mode, flag) in expected {
            let flags = try MySQLClientArguments.tls(ssl(mode), flavor: .mysql, toolPath: "/usr/bin/mysqldump")
            #expect(flags == [flag], "\(mode.rawValue) should map to \(flag)")
        }
    }

    /// MariaDB has no `--ssl-mode` at all: measured, it answers `unknown variable 'ssl-mode=...'`
    /// and exits 7 whatever the value.
    @Test("MariaDB's tools never see --ssl-mode")
    func mariaDBNeverSeesSSLMode() throws {
        for mode in SSLMode.allCases {
            let flags = try MySQLClientArguments.tls(ssl(mode), flavor: .mariadb, toolPath: "/usr/bin/mysqldump")
            #expect(!flags.contains { $0.hasPrefix("--ssl-mode") }, "\(mode.rawValue) leaked --ssl-mode")
        }
    }

    /// `--ssl` on its own falls back to plaintext against a server without TLS and exits 0, so it
    /// cannot carry Required. Only `--ssl-verify-server-cert` refuses that server.
    @Test("MariaDB's spelling distinguishes preferred from required")
    func mariaDBSpelling() throws {
        #expect(
            try MySQLClientArguments.tls(ssl(.disabled), flavor: .mariadb, toolPath: "/t") == ["--skip-ssl"]
        )
        #expect(
            try MySQLClientArguments.tls(ssl(.preferred), flavor: .mariadb, toolPath: "/t")
                == ["--ssl", "--skip-ssl-verify-server-cert"]
        )
        for mode in [SSLMode.required, .verifyCa, .verifyIdentity] {
            #expect(
                try MySQLClientArguments.tls(ssl(mode), flavor: .mariadb, toolPath: "/t")
                    == ["--ssl", "--ssl-verify-server-cert"]
            )
        }
    }

    // Measured with mariadb-dump 13.0.2: --ssl falls back to plaintext and answers caching_sha2_password's full
    // authentication with the typed password, where --skip-ssl asks for the server's RSA key.
    @Test("MariaDB's Preferred follows the server's greeting, MySQL's does not need to")
    func preferredFollowsTheGreeting() throws {
        #expect(
            try MySQLClientArguments.tls(ssl(.preferred), flavor: .mariadb, toolPath: "/t", serverOffersTLS: false)
                == ["--skip-ssl"]
        )
        #expect(
            try MySQLClientArguments.tls(ssl(.preferred), flavor: .mariadb, toolPath: "/t", serverOffersTLS: true)
                == ["--ssl", "--skip-ssl-verify-server-cert"]
        )
        #expect(
            try MySQLClientArguments.tls(ssl(.preferred), flavor: .mysql, toolPath: "/t", serverOffersTLS: false)
                == ["--ssl-mode=PREFERRED"]
        )
        #expect(
            try MySQLClientArguments.tls(ssl(.required), flavor: .mariadb, toolPath: "/t", serverOffersTLS: false)
                == ["--ssl", "--ssl-verify-server-cert"]
        )
    }

    @Test("The CA goes with the modes that verify one, and the client pair always follows")
    func certificatePaths() throws {
        let verifying = ssl(.verifyCa, ca: "/certs/ca.pem", certificate: "/certs/c.pem", key: "/certs/c.key")
        for flavor in [NativeDumpToolFlavor.mysql, .mariadb] {
            let flags = try MySQLClientArguments.tls(verifying, flavor: flavor, toolPath: "/t")
            #expect(flags.contains("--ssl-ca=/certs/ca.pem"))
            #expect(flags.contains("--ssl-cert=/certs/c.pem"))
            #expect(flags.contains("--ssl-key=/certs/c.key"))
        }

        let required = ssl(.required, ca: "/certs/ca.pem", certificate: "/certs/c.pem")
        let flags = try MySQLClientArguments.tls(required, flavor: .mysql, toolPath: "/t")
        #expect(!flags.contains { $0.hasPrefix("--ssl-ca") })
        #expect(flags.contains("--ssl-cert=/certs/c.pem"))
    }

    /// `--ssl-cert` implies `--ssl` on MariaDB, so a connection the user turned SSL off on must not
    /// carry the paths its form still holds.
    @Test("An SSL-off connection sends no certificate paths")
    func disabledSendsNothingElse() throws {
        let stale = ssl(.disabled, ca: "/certs/ca.pem", certificate: "/certs/c.pem", key: "/certs/c.key")
        #expect(try MySQLClientArguments.tls(stale, flavor: .mariadb, toolPath: "/t") == ["--skip-ssl"])
        #expect(try MySQLClientArguments.tls(stale, flavor: .mysql, toolPath: "/t") == ["--ssl-mode=DISABLED"])
    }

    /// Guessing costs more than refusing here: MariaDB accepts `--loose-ssl-mode=REQUIRED`, ignores
    /// it, and sends the dump in cleartext.
    @Test("An unidentified tool refuses every mode that promises encryption")
    func unidentifiedRefusesEncryptedModes() throws {
        for mode in [SSLMode.required, .verifyCa, .verifyIdentity] {
            #expect(throws: NativeDumpError.self) {
                try MySQLClientArguments.tls(ssl(mode), flavor: .unidentified, toolPath: "/usr/bin/mysqldump")
            }
        }
        #expect(try MySQLClientArguments.tls(ssl(.preferred), flavor: .unidentified, toolPath: "/t").isEmpty)
        #expect(try MySQLClientArguments.tls(ssl(.disabled), flavor: .unidentified, toolPath: "/t").isEmpty)
    }

    private func tool(_ flavor: NativeDumpToolFlavor, _ versionText: String?) -> NativeDumpResolvedTool {
        NativeDumpResolvedTool(name: "mysqldump", path: "/usr/bin/mysqldump", flavor: flavor, versionText: versionText)
    }

    private static let mysql8 = "mysqldump  Ver 8.4.11 for macos26.6 on arm64 (Homebrew)"
    private static let mysql57 = "mysqldump  Ver 10.13 Distrib 5.7.44, for osx10.17 (x86_64)"
    private static let mariaDB = "mysqldump from 12.3.3-MariaDB, client 10.20 for osx10.21 (arm64)"

    /// Measured against MariaDB 12.3.3: without the flag mysqldump 8.4.11 stops on
    /// `Unknown table 'column_statistics' in information_schema (1109)` and exits 2 having written
    /// part of the file.
    @Test("Column statistics are skipped only where the server has none and the tool asks for them")
    func columnStatistics() {
        #expect(
            MySQLClientArguments.dumpCompatibility(
                tool: tool(.mysql, Self.mysql8), serverVersion: "12.3.3-MariaDB"
            ) == ["--skip-column-statistics"]
        )
        #expect(
            MySQLClientArguments.dumpCompatibility(
                tool: tool(.mysql, Self.mysql8), serverVersion: "5.7.44-log"
            ) == ["--skip-column-statistics"]
        )
        #expect(
            MySQLClientArguments.dumpCompatibility(
                tool: tool(.mysql, Self.mysql8), serverVersion: "8.0.36"
            ).isEmpty
        )
        #expect(
            MySQLClientArguments.dumpCompatibility(
                tool: tool(.mysql, Self.mysql57), serverVersion: "12.3.3-MariaDB"
            ).isEmpty,
            "a 5.7 tool does not know the flag and never reads the table"
        )
        #expect(
            MySQLClientArguments.dumpCompatibility(
                tool: tool(.mariadb, Self.mariaDB), serverVersion: "12.3.3-MariaDB"
            ).isEmpty,
            "MariaDB's own tool answers unknown option"
        )
        #expect(
            MySQLClientArguments.dumpCompatibility(
                tool: tool(.mysql, Self.mysql8), serverVersion: nil
            ).isEmpty,
            "an unreadable server banner keeps the argument list it has always had"
        )
    }

    @Test("The column statistics table is read off the server's own banner")
    func serverColumnStatistics() {
        #expect(!MySQLClientArguments.serverHasColumnStatistics("12.3.3-MariaDB"))
        #expect(!MySQLClientArguments.serverHasColumnStatistics("10.11.2-MariaDB-log"))
        #expect(!MySQLClientArguments.serverHasColumnStatistics("5.7.44-log"))
        #expect(MySQLClientArguments.serverHasColumnStatistics("8.0.36"))
        #expect(MySQLClientArguments.serverHasColumnStatistics("9.1.0"))
        #expect(MySQLClientArguments.serverHasColumnStatistics(nil))
        #expect(MySQLClientArguments.serverHasColumnStatistics(""))
    }
}
