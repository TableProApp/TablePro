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
}
