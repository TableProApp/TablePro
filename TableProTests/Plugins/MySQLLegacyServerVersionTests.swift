//
//  MySQLLegacyServerVersionTests.swift
//  TableProTests
//

import Testing

struct MySQLLegacyServerVersionTests {
    /// 4.1.22, 5.0.96, 5.1.73 and 5.5.61 were measured; the rest are the documented floors.
    private static let ladder = [
        "4.1.22-standard", "5.0.0-alpha", "5.0.2", "5.0.3", "5.0.10", "5.0.96-log",
        "5.1.6", "5.1.10", "5.1.73", "5.5.3", "5.5.61",
    ]

    private func banners(where gate: (String?, MySQLServerFlavor) -> Bool) -> [String] {
        Self.ladder.filter { gate($0, MySQLServerFlavor.fromBanner($0)) }
    }

    private func ladder(from banner: String) -> [String] {
        Array(Self.ladder.drop { $0 != banner })
    }

    private func ladder(below banner: String) -> [String] {
        Array(Self.ladder.prefix { $0 != banner })
    }

    private func legacyGates(banner: String?, flavor: MySQLServerFlavor) -> [String] {
        let modern: [(gate: String, holds: Bool)] = [
            ("information_schema", MySQLServerVersion.hasInformationSchema(banner: banner, flavor: flavor)),
            ("TRIGGERS", MySQLServerVersion.hasTriggerCatalog(banner: banner, flavor: flavor)),
            ("SHOW WHERE", MySQLServerVersion.showAcceptsWhere(banner: banner, flavor: flavor)),
            ("KILL QUERY", MySQLServerVersion.canStopStatementAlone(banner: banner, flavor: flavor)),
            ("SHOW text labels", !MySQLServerVersion.labelsShowTextAsBinary(banner: banner, flavor: flavor)),
            ("PARTITIONS, EVENTS", MySQLServerVersion.hasPartitionAndEventCatalogs(banner: banner, flavor: flavor)),
            ("REFERENTIAL_CONSTRAINTS", MySQLServerVersion.hasReferentialConstraintsCatalog(banner: banner, flavor: flavor)),
            ("PARAMETERS", MySQLServerVersion.hasParametersCatalog(banner: banner, flavor: flavor)),
            ("InnoDB comment", !MySQLServerVersion.appendsInnoDBStatusToComment(banner: banner, flavor: flavor)),
            ("CREATE USER", MySQLServerVersion.hasCreateUser(banner: banner, flavor: flavor)),
            ("max_user_connections", MySQLServerVersion.hasUserConnectionLimit(banner: banner, flavor: flavor)),
        ]
        return modern.filter { !$0.holds }.map(\.gate)
    }

    /// Measured on 4.1.22: the catalog answers 1146 and `SHOW FULL TABLES` answers 1064.
    @Test("information_schema, SHOW FULL TABLES and CREATE USER start at 5.0.2")
    func catalogFloor() {
        #expect(banners(where: MySQLServerVersion.hasInformationSchema(banner:flavor:)) == ladder(from: "5.0.2"))
        #expect(banners(where: MySQLServerVersion.hasCreateUser(banner:flavor:)) == ladder(from: "5.0.2"))
    }

    /// Measured on 4.1.22: `SHOW ... WHERE` answers 1064 and `max_user_connections` answers 1054.
    @Test("SHOW ... WHERE and the user connection limit start at 5.0.3")
    func showWhereFloor() {
        #expect(banners(where: MySQLServerVersion.showAcceptsWhere(banner:flavor:)) == ladder(from: "5.0.3"))
        #expect(banners(where: MySQLServerVersion.hasUserConnectionLimit(banner:flavor:)) == ladder(from: "5.0.3"))
    }

    @Test("The trigger catalog starts at 5.0.10, after the rest of information_schema")
    func triggerFloor() {
        #expect(banners(where: MySQLServerVersion.hasTriggerCatalog(banner:flavor:)) == ladder(from: "5.0.10"))
    }

    /// Measured on 4.1.22: `KILL QUERY` answers 1204.
    @Test("KILL QUERY starts at 5.0.0, so only 4.1 has to end the session to stop a statement")
    func killQueryFloor() {
        #expect(banners(where: MySQLServerVersion.canStopStatementAlone(banner:flavor:)) == ladder(from: "5.0.0-alpha"))
    }

    /// Measured: charset 63 with `BINARY_FLAG` on 4.1.22, utf8 on 5.0.96 and 5.1.73.
    @Test("Only a server before 5.0 labels SHOW text as binary")
    func binaryShowTextCeiling() {
        #expect(banners(where: MySQLServerVersion.labelsShowTextAsBinary(banner:flavor:)) == ["4.1.22-standard"])
    }

    /// Measured: 5.0.96 answers 1109 for all three, 5.1.73 reads them.
    @Test("PARTITIONS and EVENTS start at 5.1.6, REFERENTIAL_CONSTRAINTS at 5.1.10")
    func fiveOneCatalogFloors() {
        #expect(banners(where: MySQLServerVersion.hasPartitionAndEventCatalogs(banner:flavor:)) == ladder(from: "5.1.6"))
        #expect(
            banners(where: MySQLServerVersion.hasReferentialConstraintsCatalog(banner:flavor:)) == ladder(from: "5.1.10")
        )
    }

    /// Measured: 5.1.73 answers 1109, 5.5.61 reads it.
    @Test("PARAMETERS starts at 5.5.3")
    func parametersFloor() {
        #expect(banners(where: MySQLServerVersion.hasParametersCatalog(banner:flavor:)) == ladder(from: "5.5.3"))
    }

    /// Measured: EUC-KR error text on 4.1.22, 5.0.96 and 5.1.73, UTF-8 on 5.5.61. The InnoDB status was
    /// measured in the comment on 4.1.22 and 5.0.96 only, and the 5.1 release that dropped it is unknown.
    @Test("Every server before 5.5 appends the InnoDB status to comments and sends errors in its language's charset")
    func beforeFiveFive() {
        #expect(banners(where: MySQLServerVersion.appendsInnoDBStatusToComment(banner:flavor:)) == ladder(below: "5.5.3"))
        let sendsLanguageCharset = banners(where: { banner, _ in MySQLServerVersion.sendsErrorsInLanguageCharset(banner: banner) })
        #expect(sendsLanguageCharset == ladder(below: "5.5.3"))
    }

    @Test("MariaDB 5.3 reads as the MySQL 5.1 it is built on")
    func mariaDBFiveThree() {
        let banner = "5.3.12-MariaDB"
        let flavor = MySQLServerFlavor.fromBanner(banner)

        #expect(flavor == .mariadb)
        #expect(legacyGates(banner: banner, flavor: flavor) == ["PARAMETERS", "InnoDB comment"])
        #expect(MySQLServerVersion.sendsErrorsInLanguageCharset(banner: banner))
    }

    @Test("A current MariaDB or TiDB is never read as legacy")
    func currentServersAreModern() {
        #expect(legacyGates(banner: "10.6.16-MariaDB", flavor: .mariadb).isEmpty)
        #expect(!MySQLServerVersion.sendsErrorsInLanguageCharset(banner: "10.6.16-MariaDB"))

        let tidb = "8.0.11-TiDB-v7.5.1"
        #expect(legacyGates(banner: tidb, flavor: .tidb(version: MySQLEngineVersion(major: 7, minor: 5, patch: 1))).isEmpty)
        #expect(!MySQLServerVersion.sendsErrorsInLanguageCharset(banner: tidb))
    }

    /// A proxy can answer with any banner, and a gate that picks legacy syntax for it breaks a modern server.
    @Test("An unreadable or missing banner is a modern server")
    func unreadableBannerIsModern() {
        for banner in ["", "ProxySQL", nil] as [String?] {
            #expect(legacyGates(banner: banner, flavor: .mysql).isEmpty, "\(String(describing: banner))")
            #expect(!MySQLServerVersion.sendsErrorsInLanguageCharset(banner: banner), "\(String(describing: banner))")
        }
    }

    @Test("A flavor that is not MySQL or MariaDB never takes the legacy paths, whatever its banner says")
    func otherFlavorsAreNeverLegacy() {
        for flavor in [MySQLServerFlavor.tidb(version: nil), .oceanbase(version: nil), .databend] {
            #expect(legacyGates(banner: "4.1.22-standard", flavor: flavor).isEmpty, "\(flavor)")
        }
    }
}
