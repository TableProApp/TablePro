//
//  ClickHouseTableOperationsTests.swift
//  TableProTests
//

import Testing

struct ClickHouseTableOperationsTests {
    @Test("MergeTree engine classifies as TABLE")
    func mergeTreeIsTable() {
        #expect(clickHouseTableType(forEngine: "MergeTree") == "TABLE")
    }

    @Test("View engine classifies as VIEW")
    func viewIsView() {
        #expect(clickHouseTableType(forEngine: "View") == "VIEW")
    }

    @Test("MaterializedView engine classifies as MATERIALIZED VIEW")
    func materializedViewIsDistinctFromView() {
        #expect(clickHouseTableType(forEngine: "MaterializedView") == "MATERIALIZED VIEW")
    }

    @Test("LiveView and WindowView engines classify as VIEW")
    func experimentalViewEnginesAreViews() {
        #expect(clickHouseTableType(forEngine: "LiveView") == "VIEW")
        #expect(clickHouseTableType(forEngine: "WindowView") == "VIEW")
    }

    @Test("Nil engine classifies as TABLE")
    func nilEngineIsTable() {
        #expect(clickHouseTableType(forEngine: nil) == "TABLE")
    }

    @Test("Materialized view drops via DROP VIEW")
    func dropMaterializedViewUsesViewKeyword() {
        let stmt = clickHouseDropObjectStatement(name: "daily_sales", objectType: "MATERIALIZED VIEW")
        #expect(stmt == "DROP VIEW `daily_sales`")
    }

    @Test("Backticks in the name are escaped")
    func escapesBackticks() {
        let stmt = clickHouseDropObjectStatement(name: "weird`name", objectType: "MATERIALIZED VIEW")
        #expect(stmt == "DROP VIEW `weird``name`")
    }

    @Test("Other object types fall through to the default statement")
    func otherTypesReturnNil() {
        #expect(clickHouseDropObjectStatement(name: "orders", objectType: "TABLE") == nil)
        #expect(clickHouseDropObjectStatement(name: "active_users", objectType: "VIEW") == nil)
    }

    // MARK: - Comments

    private let commentCapable = ClickHouseCapabilities.parse("23.9")

    @Test("A table comment uses MODIFY COMMENT")
    func tableCommentStatement() {
        #expect(clickHouseCommentStatement(
            name: "orders", database: nil, objectType: "TABLE", comment: "Orders", capabilities: commentCapable
        ) == "ALTER TABLE `orders` MODIFY COMMENT 'Orders'")
    }

    @Test("A named database qualifies the table and backticks are doubled")
    func tableCommentQualifiesTheDatabase() {
        #expect(clickHouseCommentStatement(
            name: "or`ders", database: "sh`op", objectType: "TABLE", comment: "x", capabilities: commentCapable
        ) == "ALTER TABLE `sh``op`.`or``ders` MODIFY COMMENT 'x'")
        #expect(clickHouseCommentStatement(
            name: "orders", database: "", objectType: "TABLE", comment: "x", capabilities: commentCapable
        ) == "ALTER TABLE `orders` MODIFY COMMENT 'x'")
    }

    @Test("A nil or empty comment clears it with an empty literal", arguments: [nil, ""] as [String?])
    func emptyCommentClears(comment: String?) {
        #expect(clickHouseCommentStatement(
            name: "orders", database: nil, objectType: "TABLE", comment: comment, capabilities: commentCapable
        ) == "ALTER TABLE `orders` MODIFY COMMENT ''")
    }

    @Test("Quotes, backslashes and line breaks are escaped")
    func commentIsEscaped() {
        #expect(clickHouseCommentStatement(
            name: "t", database: nil, objectType: "TABLE", comment: "it's C:\\tmp\nnext", capabilities: commentCapable
        ) == #"ALTER TABLE `t` MODIFY COMMENT 'it''s C:\\tmp\nnext'"#)
    }

    @Test("Views and materialized views get no comment statement", arguments: ["VIEW", "MATERIALIZED VIEW", "SYSTEM TABLE"])
    func nonTablesReturnNil(objectType: String) {
        #expect(clickHouseCommentStatement(
            name: "v", database: nil, objectType: objectType, comment: "x", capabilities: commentCapable
        ) == nil)
    }

    @Test("A server before 23.9, or of unknown version, gets no comment statement", arguments: ["23.8", "21.3.20.1", nil] as [String?])
    func olderServersReturnNil(version: String?) {
        #expect(clickHouseCommentStatement(
            name: "t", database: nil, objectType: "TABLE", comment: "x", capabilities: ClickHouseCapabilities.parse(version)
        ) == nil)
    }

    @Test("A backslash in a name is doubled before the backquote, so it cannot end the name early")
    func quotedIdentifierEscapesBackslash() {
        #expect(clickHouseQuotedIdentifier("orders") == "`orders`")
        #expect(clickHouseQuotedIdentifier("a`b") == "`a``b`")
        #expect(clickHouseQuotedIdentifier("x\\`; DROP TABLE t; --") == "`x\\\\``; DROP TABLE t; --`")
    }

    @Test("A backquote followed by a combining mark is still doubled")
    func quotedIdentifierSeesBackquoteBeforeCombiningMark() {
        let quoted = clickHouseQuotedIdentifier("a`\u{0301}b")
        #expect(quoted.unicodeScalars.filter { $0 == "`" }.count == 4)
    }

    @Test("The comment statement quotes the table with the escaping quoter")
    func commentStatementQuotesBackslashNames() {
        let statement = clickHouseCommentStatement(
            name: "x\\`y", database: "db", objectType: "TABLE", comment: "c",
            capabilities: ClickHouseCapabilities.parse("24.3.1")
        )
        #expect(statement == "ALTER TABLE `db`.`x\\\\``y` MODIFY COMMENT 'c'")
    }
}
