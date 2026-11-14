import Testing

struct MySQLServerVersionTests {
    @Test("MariaDB 10.1 has generated columns but no GENERATION_EXPRESSION column")
    func generationExpressionFloor() {
        #expect(!MySQLServerVersion.hasGenerationExpression(banner: "10.1.48-MariaDB", flavor: .mariadb))
        #expect(MySQLServerVersion.hasGenerationExpression(banner: "10.2.0-MariaDB", flavor: .mariadb))
        #expect(!MySQLServerVersion.hasGenerationExpression(banner: "5.7.5", flavor: .mysql))
        #expect(MySQLServerVersion.hasGenerationExpression(banner: "5.7.6", flavor: .mysql))
    }

    @Test("an unreadable banner is treated as unsupported rather than assumed modern")
    func unknownBannerIsUnsupported() {
        #expect(!MySQLServerVersion.hasGenerationExpression(banner: nil, flavor: .mysql))
        #expect(!MySQLServerVersion.hasGenerationExpression(banner: "unknown", flavor: .mysql))
    }

    @Test("READ ONLY transactions start at MySQL 5.6.5 and MariaDB 10.0, an unreadable banner is not an old server, and no other flavor has them")
    func readOnlyTransactionFloor() {
        #expect(!MySQLServerVersion.hasReadOnlyTransactions(banner: "5.6.4-log", flavor: .mysql))
        #expect(MySQLServerVersion.hasReadOnlyTransactions(banner: "5.6.5", flavor: .mysql))
        #expect(MySQLServerVersion.hasReadOnlyTransactions(banner: "8.4.13", flavor: .mysql))
        #expect(!MySQLServerVersion.hasReadOnlyTransactions(banner: "5.5.64-MariaDB", flavor: .mariadb))
        #expect(MySQLServerVersion.hasReadOnlyTransactions(banner: "10.0.0-MariaDB", flavor: .mariadb))
        #expect(MySQLServerVersion.hasReadOnlyTransactions(banner: "11.4.13-MariaDB", flavor: .mariadb))
        #expect(MySQLServerVersion.hasReadOnlyTransactions(banner: nil, flavor: .mysql))
        #expect(MySQLServerVersion.hasReadOnlyTransactions(banner: "unknown", flavor: .mariadb))
        #expect(!MySQLServerVersion.hasReadOnlyTransactions(banner: "8.0.11-TiDB-v8.5.1", flavor: .tidb(version: nil)))
        #expect(!MySQLServerVersion.hasReadOnlyTransactions(banner: "5.7.25", flavor: .oceanbase(version: nil)))
        #expect(!MySQLServerVersion.hasReadOnlyTransactions(banner: "8.0.0", flavor: .databend))
        #expect(!MySQLServerVersion.hasReadOnlyTransactions(banner: "8.0.33", flavor: .starrocks))
    }

    /// The other direction: a gate that picks legacy syntax has to hear a version before it does,
    /// because the legacy statements are a 1064 on MySQL 8.
    @Test("isKnownBelow answers false for a banner it cannot read")
    func isKnownBelowNeedsAVersion() {
        #expect(MySQLServerVersion.isKnownBelow((5, 7, 6), banner: "5.6.51"))
        #expect(!MySQLServerVersion.isKnownBelow((5, 7, 6), banner: "8.4.11"))
        #expect(!MySQLServerVersion.isKnownBelow((5, 7, 6), banner: nil))
        #expect(!MySQLServerVersion.isKnownBelow((5, 7, 6), banner: "unknown"))
    }
}
