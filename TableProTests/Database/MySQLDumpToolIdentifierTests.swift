//
//  MySQLDumpToolIdentifierTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// The version strings here are verbatim output from the binaries on a Mac with both families
/// installed, including the renamed copy that proves the token comes from the build rather than
/// from `argv[0]`.
@Suite("MySQL dump tool identifier")
struct MySQLDumpToolIdentifierTests {
    private static let mariaDB = "/opt/homebrew/bin/mysqldump from 12.3.3-MariaDB, client 10.20 for osx10.21 (arm64)"
    private static let renamedMariaDB = "./totally-not-mariadb from 12.3.3-MariaDB, client 10.20 for osx10.21 (arm64)"
    private static let mysql84 = "mysqldump  Ver 8.4.11 for macos26.6 on arm64 (Homebrew)"
    private static let mysql57 = "mysqldump  Ver 10.13 Distrib 5.7.44, for osx10.17 (x86_64)"

    /// Homebrew installs MariaDB's dump tool as `mysqldump`, so the name proves nothing and the
    /// banner is the answer (#3046).
    @Test("A MariaDB tool is recognized whatever it is called")
    func mariaDBFromBanner() {
        #expect(MySQLDumpToolIdentifier.flavor(name: "mysqldump", versionText: Self.mariaDB) == .mariadb)
        let renamed = MySQLDumpToolIdentifier.flavor(name: "totally-not-mariadb", versionText: Self.renamedMariaDB)
        #expect(renamed == .mariadb)
        #expect(MySQLDumpToolIdentifier.flavor(name: "mysql", versionText: Self.mariaDB) == .mariadb)
    }

    @Test("A banner without the MariaDB token is MySQL's")
    func mysqlFromBanner() {
        #expect(MySQLDumpToolIdentifier.flavor(name: "mysqldump", versionText: Self.mysql84) == .mysql)
        #expect(MySQLDumpToolIdentifier.flavor(name: "mariadb-dump", versionText: Self.mysql84) == .mysql)
        #expect(MySQLDumpToolIdentifier.flavor(name: "mysqldump", versionText: Self.mysql57) == .mysql)
    }

    /// MariaDB renamed its clients in 11.0, so those names still answer when the tool itself will
    /// not. A binary called `mysqldump` that says nothing stays unidentified rather than being
    /// assumed to be either one.
    @Test("A tool that answers nothing falls back to its name, and only that far")
    func unreadableVersion() {
        #expect(MySQLDumpToolIdentifier.flavor(name: "mariadb-dump", versionText: nil) == .mariadb)
        #expect(MySQLDumpToolIdentifier.flavor(name: "mariadb", versionText: "") == .mariadb)
        #expect(MySQLDumpToolIdentifier.flavor(name: "mysqldump", versionText: nil) == .unidentified)
        #expect(MySQLDumpToolIdentifier.flavor(name: "mysql", versionText: "") == .unidentified)
    }

    /// `Ver` carries the tool's own version on 5.7 and the release on 8, so reading it alone makes
    /// a 5.7 client look like a 10.
    @Test("The MySQL release is read from Distrib when the banner carries one")
    func majorVersion() {
        #expect(MySQLDumpToolIdentifier.majorVersion(fromVersionText: Self.mysql84) == 8)
        #expect(MySQLDumpToolIdentifier.majorVersion(fromVersionText: Self.mysql57) == 5)
        let mysql80 = "mysqldump  Ver 8.0.36 for macos14 on arm64"
        #expect(MySQLDumpToolIdentifier.majorVersion(fromVersionText: mysql80) == 8)
        #expect(MySQLDumpToolIdentifier.majorVersion(fromVersionText: Self.mariaDB) == nil)
        #expect(MySQLDumpToolIdentifier.majorVersion(fromVersionText: nil) == nil)
    }

    @Test("Identifying a tool keeps what it said, so nothing probes it twice")
    func identifyCarriesTheBanner() {
        let resolved = MySQLDumpToolIdentifier.identify(
            name: "mysqldump",
            path: "/opt/homebrew/bin/mysqldump",
            probe: { _ in Self.mariaDB + "\n" }
        )
        #expect(resolved.flavor == .mariadb)
        #expect(resolved.versionText == Self.mariaDB)
        #expect(resolved.path == "/opt/homebrew/bin/mysqldump")
        #expect(resolved.executableURL.path == "/opt/homebrew/bin/mysqldump")
    }

    @Test("A tool that cannot be run is reported unidentified rather than assumed")
    func identifyWithoutAProbe() {
        let resolved = MySQLDumpToolIdentifier.identify(
            name: "mysqldump",
            path: "/usr/bin/mysqldump",
            probe: { _ in nil }
        )
        #expect(resolved.flavor == .unidentified)
        #expect(resolved.versionText == nil)
    }
}
