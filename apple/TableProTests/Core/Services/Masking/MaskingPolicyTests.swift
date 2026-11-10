//
//  MaskingPolicyTests.swift
//  TableProTests
//

import CloudKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct MaskingPolicyTests {
    private let emailRule = MaskingPolicy(rules: [MaskingRule(pattern: "*.email", style: .email)])

    @Test("A table.column pattern matches its table and column, ignoring case")
    func tableColumnPatternMatches() {
        let policy = MaskingPolicy(rules: [MaskingRule(pattern: "users.ssn")])
        #expect(policy.style(table: "Users", column: "SSN", typeName: nil) == .full)
        #expect(policy.style(table: "public.users", column: "ssn", typeName: nil) == .full)
        #expect(policy.style(table: "orders", column: "ssn", typeName: nil) == nil)
        #expect(policy.style(table: "users", column: "name", typeName: nil) == nil)
    }

    @Test("Without a source table a table.column pattern matches by its column alone")
    func unknownTableMatchesByColumn() {
        let policy = MaskingPolicy(rules: [MaskingRule(pattern: "users.ssn")])
        #expect(policy.style(table: nil, column: "ssn", typeName: nil) == .full)
    }

    @Test("A bare pattern with wildcards matches any table's column")
    func wildcardColumnPattern() {
        let policy = MaskingPolicy(rules: [MaskingRule(pattern: "*password*", style: .null)])
        #expect(policy.style(table: "users", column: "password_hash", typeName: nil) == .null)
        #expect(policy.style(table: nil, column: "old_password", typeName: nil) == .null)
        #expect(policy.style(table: "users", column: "name", typeName: nil) == nil)
    }

    @Test("A type rule matches the column's declared type")
    func typeRuleMatches() {
        let policy = MaskingPolicy(rules: [MaskingRule(pattern: "inet*", target: .type)])
        #expect(policy.style(table: "hosts", column: "address", typeName: "inet") == .full)
        #expect(policy.style(table: "hosts", column: "address", typeName: "text") == nil)
        #expect(policy.style(table: "hosts", column: "address", typeName: nil) == nil)
    }

    @Test("The first matching rule wins, and an empty pattern is ignored")
    func firstRuleWins() {
        let policy = MaskingPolicy(rules: [
            MaskingRule(pattern: "  "),
            MaskingRule(pattern: "*.email", style: .hash),
            MaskingRule(pattern: "email", style: .full),
        ])
        #expect(policy.rules.count == 2)
        #expect(policy.style(table: "users", column: "email", typeName: nil) == .hash)
    }

    @Test("Each style hides the value as the issue describes")
    func styles() {
        let email: PluginCellValue = .text("jane.doe@example.com")
        #expect(MaskedValue.mask(email, style: .full) == .text("••••"))
        #expect(MaskedValue.mask(email, style: .email) == .text("j•••@example.com"))
        #expect(MaskedValue.mask(.text("4111111111111234"), style: .lastFour) == .text("••••1234"))
        #expect(MaskedValue.mask(.text("1234"), style: .lastFour) == .text("••••"))
        #expect(MaskedValue.mask(.text("not-an-email"), style: .email) == .text("••••"))
        #expect(MaskedValue.mask(email, style: .null) == .null)
        #expect(MaskedValue.mask(.null, style: .full) == .null)
        #expect(MaskedValue.mask(.bytes(Data([1, 2, 3])), style: .full) == .text("••••"))
    }

    @Test("A stable hash keeps equal values equal without showing them")
    func stableHash() throws {
        let first = try #require(MaskedValue.mask(.text("jane@example.com"), style: .hash).asText)
        let again = MaskedValue.mask(.text("jane@example.com"), style: .hash).asText
        let other = MaskedValue.mask(.text("john@example.com"), style: .hash).asText
        #expect(first == again)
        #expect(first != other)
        #expect(!first.contains("jane"))
        #expect(first.count == 12)
    }

    @Test("Column masks hide only the matched columns of a row")
    func columnMasksRow() {
        let masks = emailRule.columnMasks(table: "users", columns: ["id", "email"], typeNames: [nil, nil])
        #expect(masks.maskedColumns == [1])
        #expect(masks.row([.text("7"), .text("jane@example.com")]) == [.text("7"), .text("j•••@example.com")])
    }

    @Test("Rules round-trip through the connection's synced fields, and clearing them removes the key")
    func connectionRoundTrip() {
        var connection = TestFixtures.makeConnection()
        connection.maskingRules = [MaskingRule(pattern: "*.email", style: .email), MaskingRule(pattern: "")]
        #expect(connection.additionalFields[DatabaseConnection.maskingRulesKey] != nil)
        #expect(connection.maskingRules.map(\.pattern) == ["*.email"])
        #expect(connection.maskingPolicy.style(table: "users", column: "email", typeName: nil) == .email)

        connection.maskingRules = []
        #expect(connection.additionalFields[DatabaseConnection.maskingRulesKey] == nil)
    }

    @Test("Rules travel with the connection through iCloud sync")
    func rulesSync() throws {
        var connection = TestFixtures.makeConnection()
        connection.maskingRules = [MaskingRule(pattern: "users.ssn", style: .lastFour)]
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

        let synced = try SyncRecordMapper.toConnection(SyncRecordMapper.toCKRecord(connection, in: zoneID))

        #expect(synced.maskingRules == connection.maskingRules)
    }

    @Test("An unknown style masks fully, and an unknown target or a missing pattern masks every column")
    func unreadableRulesFailClosed() throws {
        let json = #"[{"pattern":"*.email","style":"later"},{"pattern":"^ssn$","target":"regex"},{"style":"full"}]"#
        let rules = try JSONDecoder().decode([MaskingRule].self, from: Data(json.utf8))
        #expect(rules.map { $0.style } == [.full, .full, .full])
        #expect(rules.map { $0.pattern } == ["*.email", "*", "*"])
        #expect(MaskingPolicy(rules: rules).style(table: "users", column: "name", typeName: nil) == .full)
    }

    @Test("Stored rules that cannot be read at all mask every column")
    func corruptRulesFailClosed() {
        var connection = TestFixtures.makeConnection()
        connection.additionalFields[DatabaseConnection.maskingRulesKey] = "{not json"
        #expect(connection.maskingPolicy.style(table: "users", column: "name", typeName: nil) == .full)
    }

    @Test("QueryResult masking keeps everything but the masked values")
    func queryResultMasking() {
        var result = QueryResult(
            columns: ["id", "email"],
            columnTypes: [.integer(rawType: "int"), .text(rawType: "varchar")],
            rows: [[.text("1"), .text("jane@example.com")]],
            rowsAffected: 0,
            executionTime: 0.5,
            error: nil
        )
        result.isTruncated = true
        let masked = result.masked(by: emailRule)
        #expect(masked.rows == [[.text("1"), .text("j•••@example.com")]])
        #expect(masked.isTruncated)
        #expect(masked.columns == result.columns)
    }

    private static func origin(_ table: String, _ column: String) -> PluginColumnOrigin {
        PluginColumnOrigin(schema: "public", table: table, column: column)
    }

    @Test("For an external caller an aliased column is masked by the table column it reads")
    func externalAliasFollowsItsOrigin() {
        let masks = emailRule.externalColumnMasks(
            table: nil, columns: ["e", "id"], typeNames: [nil, nil],
            origins: [Self.origin("users", "email"), Self.origin("users", "id")]
        )
        #expect(masks.styles == [0: .email])
    }

    @Test("For an external caller a column nothing traced is masked whole")
    func externalUntracedColumnIsMasked() {
        let traced = emailRule.externalColumnMasks(
            table: nil, columns: ["lower", "id"], typeNames: [nil, nil], origins: [nil, Self.origin("users", "id")]
        )
        #expect(traced.styles == [0: .full])

        let unreported = emailRule.externalColumnMasks(
            table: nil, columns: ["email", "id"], typeNames: [nil, nil], origins: nil
        )
        #expect(unreported.styles == [0: .full, 1: .full])
        #expect(emailRule.untracedColumns(table: nil, columns: ["email", "id"], origins: nil) == [0, 1])
    }

    // `SELECT 'x@' || ssn AS email` would otherwise come back as `x•••@123-45-6789` under an e-mail style rule.
    @Test("An untraced column never takes the style of a rule its chosen name matches")
    func externalUntracedNameDoesNotPickTheStyle() {
        let policy = MaskingPolicy(rules: [
            MaskingRule(pattern: "*.email", style: .email),
            MaskingRule(pattern: "*.card", style: .lastFour),
            MaskingRule(pattern: "*.token", style: .hash),
        ])
        let masks = policy.externalColumnMasks(
            table: nil, columns: ["email", "card", "token"], typeNames: [nil, nil, nil], origins: [nil, nil, nil]
        )
        #expect(masks.styles == [0: .full, 1: .full, 2: .full])
    }

    // Measured: PostgreSQL names the view, partition or child table read, MariaDB the view.
    @Test("For an external caller a table.column rule matches a traced column whatever relation the engine names")
    func externalTableRuleMatchesAnyTracedRelation() {
        let policy = MaskingPolicy(rules: [MaskingRule(pattern: "users.ssn")])
        let masks = policy.externalColumnMasks(
            table: nil, columns: ["x", "ssn", "id"], typeNames: [nil, nil, nil],
            origins: [Self.origin("users", "ssn"), Self.origin("users_2024", "ssn"), Self.origin("users", "id")]
        )
        #expect(masks.styles == [0: .full, 1: .full])
    }

    @Test("A traced column takes the style of the rule naming its relation, else the first rule for its column")
    func externalTracedStylePrefersTheNamedRelation() {
        let policy = MaskingPolicy(rules: [
            MaskingRule(pattern: "audit.email", style: .hash),
            MaskingRule(pattern: "users.email", style: .email),
        ])
        let masks = policy.externalColumnMasks(
            table: nil, columns: ["email", "email"], typeNames: [nil, nil],
            origins: [Self.origin("users", "email"), Self.origin("active_users", "email")]
        )
        #expect(masks.styles == [0: .email, 1: .hash])
    }

    // `SELECT email AS contact FROM users` came back as `a•••@example.com` before.
    @Test("A traced column takes the stricter of its origin's rule and the rule its alias matches")
    func externalAliasRuleCanOnlyTightenTheStyle() {
        let policy = MaskingPolicy(rules: [
            MaskingRule(pattern: "users.email", style: .email),
            MaskingRule(pattern: "*.contact", style: .full),
            MaskingRule(pattern: "*.handle", style: .lastFour),
            MaskingRule(pattern: "*.gone", style: .null),
        ])
        let masks = policy.externalColumnMasks(
            table: nil, columns: ["contact", "handle", "gone", "e", "EMAIL"], typeNames: [nil, nil, nil, nil, nil],
            origins: Array(repeating: Self.origin("users", "email"), count: 5)
        )
        #expect(masks.styles == [0: .full, 1: .full, 2: .null, 3: .email, 4: .email])
    }

    @Test("The stricter of two styles hides what either one hides")
    func strictestStyle() {
        #expect(MaskingStyle.strictest(.email, nil) == .email)
        #expect(MaskingStyle.strictest(nil, .hash) == .hash)
        #expect(MaskingStyle.strictest(.lastFour, .lastFour) == .lastFour)
        #expect(MaskingStyle.strictest(.email, .lastFour) == .full)
        #expect(MaskingStyle.strictest(.hash, .email) == .full)
        #expect(MaskingStyle.strictest(.full, .null) == .null)
        #expect(MaskingStyle.strictest(nil, nil) == nil)
    }

    @Test("A traced column the rules miss is still masked when the name it was given matches one")
    func externalTracedColumnKeepsTheNameMatch() {
        let masks = emailRule.externalColumnMasks(
            table: nil, columns: ["email"], typeNames: [nil], origins: [Self.origin("users", "name")]
        )
        #expect(masks.styles == [0: .email])
    }

    @Test("A projection the app built from one table's own columns is matched by name")
    func externalAppProjectionMatchesByName() {
        let masks = emailRule.externalColumnMasks(
            table: "customers", columns: ["id", "email"], typeNames: [nil, nil], origins: nil
        )
        #expect(masks.styles == [1: .email])
        #expect(emailRule.untracedColumns(table: "customers", columns: ["id", "email"], origins: nil).isEmpty)
    }

    @Test("A column the driver withholds an origin for stays masked even in the app's own projection")
    func externalWithheldOriginBeatsTheTableName() {
        let masks = emailRule.externalColumnMasks(
            table: "pg_stats", columns: ["attname", "histogram_bounds"], typeNames: [nil, nil],
            origins: [Self.origin("pg_stats", "attname"), nil]
        )
        #expect(masks.styles == [1: .full])

        // A driver that distrusts the whole statement reports every column untraced, which proves nothing by name.
        let distrusted = emailRule.externalColumnMasks(
            table: "contacts_content", columns: ["c0", "c1"], typeNames: [nil, nil], origins: [nil, nil]
        )
        #expect(distrusted.styles == [0: .full, 1: .full])
    }

    private static func scope(_ database: String, _ schema: String? = nil) -> DatabaseScope {
        DatabaseScope(connectionId: UUID(), database: database, schema: schema)
    }

    // Measured on ClickHouse 26.8: `system.query_log.exception` keeps the server message the bridge withheld.
    @MainActor
    @Test("The app's projection of a system table proves nothing by name; a user table's still does")
    func appProjectionOfASystemTableIsUntraced() {
        #expect(ExternalRowMasking.table("query_log").resolved(in: Self.scope("system"), databaseType: .clickhouse) == .byOrigin)
        #expect(
            ExternalRowMasking.table("system.query_log").resolved(in: Self.scope("default"), databaseType: .clickhouse)
                == .byOrigin
        )
        #expect(ExternalRowMasking.table("events").resolved(in: Self.scope("default"), databaseType: .clickhouse) == .table("events"))
        #expect(
            ExternalRowMasking.table("pg_stat_activity").resolved(in: Self.scope("shop", "pg_catalog"), databaseType: .postgresql)
                == .byOrigin
        )
        #expect(ExternalRowMasking.table("users").resolved(in: Self.scope("shop", "public"), databaseType: .postgresql) == .table("users"))
        #expect(ExternalRowMasking.byName.resolved(in: Self.scope("system"), databaseType: .clickhouse) == .byName)
    }

    @Test("A connection with no rules masks nothing for an external caller")
    func externalWithoutRules() {
        let masks = MaskingPolicy.none.externalColumnMasks(
            table: nil, columns: ["lower"], typeNames: [nil], origins: nil
        )
        #expect(masks.isEmpty)
    }

    @Test("An external result says which columns were masked for want of an origin")
    func externalResultNamesUntracedColumns() throws {
        var result = QueryResult(
            columns: ["id", "lower(email)"],
            columnTypes: [.integer(rawType: "int"), .text(rawType: "text")],
            rows: [[.text("1"), .text("jane@example.com")]],
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
        result.columnOrigins = [Self.origin("users", "id"), nil]

        let masked = result.maskedForExternalCaller(by: emailRule)

        #expect(masked.rows == [[.text("1"), .text("••••")]])
        let note = try #require(masked.statusMessage)
        #expect(note.contains("lower(email)"))
        #expect(!note.contains("id,"))
    }
}
