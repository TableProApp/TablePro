//
//  EtcdCommandParserTests.swift
//  TableProTests
//
//  Tests for EtcdCommandParser (compiled via symlink from EtcdDriverPlugin).
//

import Foundation
import Testing

// MARK: - KV Commands

@Suite("EtcdCommandParser - GET")
struct EtcdCommandParserGetTests {
    @Test("Basic get parses key")
    func basicGet() throws {
        let op = try EtcdCommandParser.parse("get mykey")
        guard case .get(let key, let prefix, let limit, let keysOnly, let sortOrder, let sortTarget) = op else {
            Issue.record("Expected .get, got \(op)")
            return
        }
        #expect(key == "mykey")
        #expect(prefix == false)
        #expect(limit == nil)
        #expect(keysOnly == false)
        #expect(sortOrder == nil)
        #expect(sortTarget == nil)
    }

    @Test("Get with --prefix flag")
    func getWithPrefix() throws {
        let op = try EtcdCommandParser.parse("get /app/ --prefix")
        guard case .get(let key, let prefix, _, _, _, _) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(key == "/app/")
        #expect(prefix == true)
    }

    @Test("Get with --limit=N flag")
    func getWithLimitEquals() throws {
        let op = try EtcdCommandParser.parse("get key --limit=10")
        guard case .get(_, _, let limit, _, _, _) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(limit == 10)
    }

    @Test("Get with --limit N (space-separated)")
    func getWithLimitSpace() throws {
        let op = try EtcdCommandParser.parse("get key --limit 10")
        guard case .get(_, _, let limit, _, _, _) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(limit == 10)
    }

    @Test("Get with --keys-only flag")
    func getWithKeysOnly() throws {
        let op = try EtcdCommandParser.parse("get key --keys-only")
        guard case .get(_, _, _, let keysOnly, _, _) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(keysOnly == true)
    }

    @Test("Get with --order flag")
    func getWithSortOrder() throws {
        let op = try EtcdCommandParser.parse("get key --prefix --order=DESCEND")
        guard case .get(_, _, _, _, let sortOrder, _) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(sortOrder == .descend)
    }

    @Test("Get with --sort-by flag")
    func getWithSortTarget() throws {
        let op = try EtcdCommandParser.parse("get key --prefix --sort-by=KEY")
        guard case .get(_, _, _, _, _, let sortTarget) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(sortTarget == .key)
    }

    @Test("Get with all flags combined")
    func getWithAllFlags() throws {
        let op = try EtcdCommandParser.parse("get /prefix/ --prefix --limit=100 --keys-only --order=ASCEND --sort-by=MOD")
        guard case .get(let key, let prefix, let limit, let keysOnly, let sortOrder, let sortTarget) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(key == "/prefix/")
        #expect(prefix == true)
        #expect(limit == 100)
        #expect(keysOnly == true)
        #expect(sortOrder == .ascend)
        #expect(sortTarget == .modRevision)
    }

    @Test("Get missing key throws")
    func getMissingKey() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("get")
        }
    }

    @Test("Get with invalid --limit throws")
    func getInvalidLimit() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("get key --limit=abc")
        }
    }

    @Test("Get with invalid --order throws")
    func getInvalidOrder() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("get key --order=INVALID")
        }
    }

    @Test("Get with invalid --sort-by throws")
    func getInvalidSortBy() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("get key --sort-by=INVALID")
        }
    }
}

@Suite("EtcdCommandParser - PUT")
struct EtcdCommandParserPutTests {
    @Test("Basic put parses key and value")
    func basicPut() throws {
        let op = try EtcdCommandParser.parse("put mykey myvalue")
        guard case .put(let key, let value, let leaseId) = op else {
            Issue.record("Expected .put, got \(op)")
            return
        }
        #expect(key == "mykey")
        #expect(value == "myvalue")
        #expect(leaseId == nil)
    }

    @Test("Put with --lease flag")
    func putWithLease() throws {
        let op = try EtcdCommandParser.parse("put mykey myvalue --lease 123")
        guard case .put(_, _, let leaseId) = op else {
            Issue.record("Expected .put")
            return
        }
        #expect(leaseId == 123)
    }

    @Test("Put with --lease=N flag")
    func putWithLeaseEquals() throws {
        let op = try EtcdCommandParser.parse("put mykey myvalue --lease=456")
        guard case .put(_, _, let leaseId) = op else {
            Issue.record("Expected .put")
            return
        }
        #expect(leaseId == 456)
    }

    @Test("Put with quoted key and value")
    func putQuotedArgs() throws {
        let op = try EtcdCommandParser.parse("put \"my key\" \"my value\"")
        guard case .put(let key, let value, _) = op else {
            Issue.record("Expected .put")
            return
        }
        #expect(key == "my key")
        #expect(value == "my value")
    }

    @Test("Put with single-quoted args")
    func putSingleQuotedArgs() throws {
        let op = try EtcdCommandParser.parse("put 'key' 'value'")
        guard case .put(let key, let value, _) = op else {
            Issue.record("Expected .put")
            return
        }
        #expect(key == "key")
        #expect(value == "value")
    }

    @Test("Put with empty quoted key")
    func putEmptyQuotedKey() throws {
        let op = try EtcdCommandParser.parse("put \"\" \"value\"")
        guard case .put(let key, let value, _) = op else {
            Issue.record("Expected .put")
            return
        }
        #expect(key == "")
        #expect(value == "value")
    }

    @Test("Put with escape sequences in quotes")
    func putEscapeSequences() throws {
        let op = try EtcdCommandParser.parse("put \"key\" \"value\\nwith\\nnewlines\"")
        guard case .put(_, let value, _) = op else {
            Issue.record("Expected .put")
            return
        }
        #expect(value == "value\nwith\nnewlines")
    }

    @Test("Put missing arguments throws")
    func putMissingArgs() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("put mykey")
        }
    }

    @Test("Put missing all arguments throws")
    func putMissingAllArgs() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("put")
        }
    }
}

@Suite("EtcdCommandParser - DEL")
struct EtcdCommandParserDelTests {
    @Test("Basic del parses key")
    func basicDel() throws {
        let op = try EtcdCommandParser.parse("del mykey")
        guard case .del(let key, let prefix) = op else {
            Issue.record("Expected .del, got \(op)")
            return
        }
        #expect(key == "mykey")
        #expect(prefix == false)
    }

    @Test("Del with --prefix flag")
    func delWithPrefix() throws {
        let op = try EtcdCommandParser.parse("del /app/ --prefix")
        guard case .del(let key, let prefix) = op else {
            Issue.record("Expected .del")
            return
        }
        #expect(key == "/app/")
        #expect(prefix == true)
    }

    @Test("Delete alias works")
    func deleteAlias() throws {
        let op = try EtcdCommandParser.parse("delete mykey")
        guard case .del(let key, _) = op else {
            Issue.record("Expected .del")
            return
        }
        #expect(key == "mykey")
    }

    @Test("Del missing key throws")
    func delMissingKey() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("del")
        }
    }
}

@Suite("EtcdCommandParser - WATCH")
struct EtcdCommandParserWatchTests {
    @Test("Basic watch parses key")
    func basicWatch() throws {
        let op = try EtcdCommandParser.parse("watch mykey")
        guard case .watch(let key, let prefix, let timeout) = op else {
            Issue.record("Expected .watch, got \(op)")
            return
        }
        #expect(key == "mykey")
        #expect(prefix == false)
        #expect(timeout == 30)
    }

    @Test("Watch with --prefix")
    func watchWithPrefix() throws {
        let op = try EtcdCommandParser.parse("watch /app/ --prefix")
        guard case .watch(_, let prefix, _) = op else {
            Issue.record("Expected .watch")
            return
        }
        #expect(prefix == true)
    }

    @Test("Watch with --timeout")
    func watchWithTimeout() throws {
        let op = try EtcdCommandParser.parse("watch key --timeout 60")
        guard case .watch(_, _, let timeout) = op else {
            Issue.record("Expected .watch")
            return
        }
        #expect(timeout == 60)
    }

    @Test("Watch missing key throws")
    func watchMissingKey() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("watch")
        }
    }
}

// MARK: - Lease Commands

@Suite("EtcdCommandParser - Lease")
struct EtcdCommandParserLeaseTests {
    @Test("Lease grant parses TTL")
    func leaseGrant() throws {
        let op = try EtcdCommandParser.parse("lease grant 100")
        guard case .leaseGrant(let ttl) = op else {
            Issue.record("Expected .leaseGrant, got \(op)")
            return
        }
        #expect(ttl == 100)
    }

    @Test("Lease grant missing TTL throws")
    func leaseGrantMissingTtl() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("lease grant")
        }
    }

    @Test("Lease revoke parses decimal ID")
    func leaseRevokeDecimal() throws {
        let op = try EtcdCommandParser.parse("lease revoke 12345")
        guard case .leaseRevoke(let leaseId) = op else {
            Issue.record("Expected .leaseRevoke, got \(op)")
            return
        }
        #expect(leaseId == 12345)
    }

    @Test("Lease revoke parses hex ID with 0x prefix")
    func leaseRevokeHex() throws {
        let op = try EtcdCommandParser.parse("lease revoke 0x1234abcd")
        guard case .leaseRevoke(let leaseId) = op else {
            Issue.record("Expected .leaseRevoke")
            return
        }
        #expect(leaseId == 0x1234abcd)
    }

    @Test("Lease revoke parses hex ID without prefix")
    func leaseRevokeHexNoPrefix() throws {
        let op = try EtcdCommandParser.parse("lease revoke 1a2b3c")
        guard case .leaseRevoke(let leaseId) = op else {
            Issue.record("Expected .leaseRevoke")
            return
        }
        #expect(leaseId == 0x1a2b3c)
    }

    @Test("Lease revoke missing ID throws")
    func leaseRevokeMissingId() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("lease revoke")
        }
    }

    @Test("Lease timetolive parses ID")
    func leaseTimetolive() throws {
        let op = try EtcdCommandParser.parse("lease timetolive 12345")
        guard case .leaseTimetolive(let leaseId, let keys) = op else {
            Issue.record("Expected .leaseTimetolive, got \(op)")
            return
        }
        #expect(leaseId == 12345)
        #expect(keys == false)
    }

    @Test("Lease timetolive with --keys flag")
    func leaseTimetoliveWithKeys() throws {
        let op = try EtcdCommandParser.parse("lease timetolive 12345 --keys")
        guard case .leaseTimetolive(let leaseId, let keys) = op else {
            Issue.record("Expected .leaseTimetolive")
            return
        }
        #expect(leaseId == 12345)
        #expect(keys == true)
    }

    @Test("Lease list")
    func leaseList() throws {
        let op = try EtcdCommandParser.parse("lease list")
        guard case .leaseList = op else {
            Issue.record("Expected .leaseList, got \(op)")
            return
        }
    }

    @Test("Lease keep-alive parses ID")
    func leaseKeepAlive() throws {
        let op = try EtcdCommandParser.parse("lease keep-alive 999")
        guard case .leaseKeepAlive(let leaseId) = op else {
            Issue.record("Expected .leaseKeepAlive, got \(op)")
            return
        }
        #expect(leaseId == 999)
    }

    @Test("Lease missing subcommand throws")
    func leaseMissingSubcommand() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("lease")
        }
    }

    @Test("Lease unknown subcommand throws")
    func leaseUnknownSubcommand() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("lease foo")
        }
    }
}

// MARK: - Cluster Commands

@Suite("EtcdCommandParser - Cluster")
struct EtcdCommandParserClusterTests {
    @Test("Member list")
    func memberList() throws {
        let op = try EtcdCommandParser.parse("member list")
        guard case .memberList = op else {
            Issue.record("Expected .memberList, got \(op)")
            return
        }
    }

    @Test("Member missing subcommand throws")
    func memberMissingSubcommand() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("member")
        }
    }

    @Test("Member unknown subcommand throws")
    func memberUnknownSubcommand() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("member add")
        }
    }

    @Test("Endpoint status")
    func endpointStatus() throws {
        let op = try EtcdCommandParser.parse("endpoint status")
        guard case .endpointStatus = op else {
            Issue.record("Expected .endpointStatus, got \(op)")
            return
        }
    }

    @Test("Endpoint health")
    func endpointHealth() throws {
        let op = try EtcdCommandParser.parse("endpoint health")
        guard case .endpointHealth = op else {
            Issue.record("Expected .endpointHealth, got \(op)")
            return
        }
    }

    @Test("Endpoint missing subcommand throws")
    func endpointMissingSubcommand() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("endpoint")
        }
    }

    @Test("Endpoint unknown subcommand throws")
    func endpointUnknownSubcommand() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("endpoint foo")
        }
    }
}

// MARK: - Maintenance Commands

@Suite("EtcdCommandParser - Maintenance")
struct EtcdCommandParserMaintenanceTests {
    @Test("Compaction parses revision")
    func compaction() throws {
        let op = try EtcdCommandParser.parse("compaction 100")
        guard case .compaction(let revision, let physical) = op else {
            Issue.record("Expected .compaction, got \(op)")
            return
        }
        #expect(revision == 100)
        #expect(physical == false)
    }

    @Test("Compaction with --physical flag")
    func compactionPhysical() throws {
        let op = try EtcdCommandParser.parse("compaction 100 --physical")
        guard case .compaction(let revision, let physical) = op else {
            Issue.record("Expected .compaction")
            return
        }
        #expect(revision == 100)
        #expect(physical == true)
    }

    @Test("Compaction missing revision throws")
    func compactionMissingRevision() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("compaction")
        }
    }
}

// MARK: - Auth Commands

@Suite("EtcdCommandParser - Auth")
struct EtcdCommandParserAuthTests {
    @Test("Auth enable")
    func authEnable() throws {
        let op = try EtcdCommandParser.parse("auth enable")
        guard case .authEnable = op else {
            Issue.record("Expected .authEnable, got \(op)")
            return
        }
    }

    @Test("Auth disable")
    func authDisable() throws {
        let op = try EtcdCommandParser.parse("auth disable")
        guard case .authDisable = op else {
            Issue.record("Expected .authDisable, got \(op)")
            return
        }
    }

    @Test("Auth missing subcommand throws")
    func authMissingSubcommand() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("auth")
        }
    }

    @Test("Auth unknown subcommand throws")
    func authUnknownSubcommand() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("auth foo")
        }
    }
}

// MARK: - User Commands

@Suite("EtcdCommandParser - User")
struct EtcdCommandParserUserTests {
    @Test("User add with name only")
    func userAddNameOnly() throws {
        let op = try EtcdCommandParser.parse("user add alice")
        guard case .userAdd(let name, let password) = op else {
            Issue.record("Expected .userAdd, got \(op)")
            return
        }
        #expect(name == "alice")
        #expect(password == nil)
    }

    @Test("User add with name and password")
    func userAddWithPassword() throws {
        let op = try EtcdCommandParser.parse("user add alice secret123")
        guard case .userAdd(let name, let password) = op else {
            Issue.record("Expected .userAdd")
            return
        }
        #expect(name == "alice")
        #expect(password == "secret123")
    }

    @Test("User delete")
    func userDelete() throws {
        let op = try EtcdCommandParser.parse("user delete bob")
        guard case .userDelete(let name) = op else {
            Issue.record("Expected .userDelete, got \(op)")
            return
        }
        #expect(name == "bob")
    }

    @Test("User list")
    func userList() throws {
        let op = try EtcdCommandParser.parse("user list")
        guard case .userList = op else {
            Issue.record("Expected .userList, got \(op)")
            return
        }
    }

    @Test("User grant-role")
    func userGrantRole() throws {
        let op = try EtcdCommandParser.parse("user grant-role alice admin")
        guard case .userGrantRole(let user, let role) = op else {
            Issue.record("Expected .userGrantRole, got \(op)")
            return
        }
        #expect(user == "alice")
        #expect(role == "admin")
    }

    @Test("User revoke-role")
    func userRevokeRole() throws {
        let op = try EtcdCommandParser.parse("user revoke-role alice admin")
        guard case .userRevokeRole(let user, let role) = op else {
            Issue.record("Expected .userRevokeRole, got \(op)")
            return
        }
        #expect(user == "alice")
        #expect(role == "admin")
    }

    @Test("User grant-role missing arguments throws")
    func userGrantRoleMissingArgs() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("user grant-role alice")
        }
    }

    @Test("User revoke-role missing arguments throws")
    func userRevokeRoleMissingArgs() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("user revoke-role")
        }
    }

    @Test("User add missing name throws")
    func userAddMissingName() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("user add")
        }
    }

    @Test("User delete missing name throws")
    func userDeleteMissingName() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("user delete")
        }
    }

    @Test("User missing subcommand throws")
    func userMissingSubcommand() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("user")
        }
    }

    @Test("User unknown subcommand throws")
    func userUnknownSubcommand() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("user foo")
        }
    }
}

// MARK: - Role Commands

@Suite("EtcdCommandParser - Role")
struct EtcdCommandParserRoleTests {
    @Test("Role add")
    func roleAdd() throws {
        let op = try EtcdCommandParser.parse("role add admin")
        guard case .roleAdd(let name) = op else {
            Issue.record("Expected .roleAdd, got \(op)")
            return
        }
        #expect(name == "admin")
    }

    @Test("Role delete")
    func roleDelete() throws {
        let op = try EtcdCommandParser.parse("role delete admin")
        guard case .roleDelete(let name) = op else {
            Issue.record("Expected .roleDelete, got \(op)")
            return
        }
        #expect(name == "admin")
    }

    @Test("Role list")
    func roleList() throws {
        let op = try EtcdCommandParser.parse("role list")
        guard case .roleList = op else {
            Issue.record("Expected .roleList, got \(op)")
            return
        }
    }

    @Test("Role add missing name throws")
    func roleAddMissingName() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("role add")
        }
    }

    @Test("Role delete missing name throws")
    func roleDeleteMissingName() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("role delete")
        }
    }

    @Test("Role missing subcommand throws")
    func roleMissingSubcommand() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("role")
        }
    }

    @Test("Role unknown subcommand throws")
    func roleUnknownSubcommand() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("role foo")
        }
    }
}

// MARK: - Error Cases

@Suite("EtcdCommandParser - Error Cases")
struct EtcdCommandParserErrorTests {
    @Test("Empty string throws emptySyntax")
    func emptyInput() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("")
        }
    }

    @Test("Whitespace-only input throws emptySyntax")
    func whitespaceOnly() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parse("   ")
        }
    }

    @Test("Unknown command returns .unknown")
    func unknownCommand() throws {
        let op = try EtcdCommandParser.parse("foobar arg1 arg2")
        guard case .unknown(let command, let args) = op else {
            Issue.record("Expected .unknown, got \(op)")
            return
        }
        #expect(command == "foobar")
        #expect(args == ["arg1", "arg2"])
    }
}

// MARK: - Tokenizer / Edge Cases

@Suite("EtcdCommandParser - Tokenizer")
struct EtcdCommandParserTokenizerTests {
    @Test("Extra whitespace between tokens is handled")
    func extraWhitespace() throws {
        let op = try EtcdCommandParser.parse("get   mykey")
        guard case .get(let key, _, _, _, _, _) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(key == "mykey")
    }

    @Test("Leading and trailing whitespace is trimmed")
    func leadingTrailingWhitespace() throws {
        let op = try EtcdCommandParser.parse("  get mykey  ")
        guard case .get(let key, _, _, _, _, _) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(key == "mykey")
    }

    @Test("Multiple spaces between all tokens")
    func multipleSpacesEverywhere() throws {
        let op = try EtcdCommandParser.parse("  put   key   value  ")
        guard case .put(let key, let value, _) = op else {
            Issue.record("Expected .put")
            return
        }
        #expect(key == "key")
        #expect(value == "value")
    }

    @Test("Backslash outside quotes preserved")
    func backslashOutsideQuotes() throws {
        let op = try EtcdCommandParser.parse("put C:\\path value")
        guard case .put(let key, _, _) = op else {
            Issue.record("Expected .put")
            return
        }
        #expect(key == "C:\\path")
    }

    @Test("Tab and return escape sequences inside double quotes")
    func tabAndReturnEscapes() throws {
        let op = try EtcdCommandParser.parse("put \"key\" \"a\\tb\\rc\"")
        guard case .put(_, let value, _) = op else {
            Issue.record("Expected .put")
            return
        }
        #expect(value == "a\tb\rc")
    }

    @Test("Escaped backslash inside quotes")
    func escapedBackslashInQuotes() throws {
        let op = try EtcdCommandParser.parse("put \"key\" \"a\\\\b\"")
        guard case .put(_, let value, _) = op else {
            Issue.record("Expected .put")
            return
        }
        #expect(value == "a\\b")
    }

    @Test("Escaped double quote inside double quotes")
    func escapedQuoteInQuotes() throws {
        let op = try EtcdCommandParser.parse("put \"key\" \"say \\\"hi\\\"\"")
        guard case .put(_, let value, _) = op else {
            Issue.record("Expected .put")
            return
        }
        #expect(value == "say \"hi\"")
    }

    @Test("Case insensitivity for commands")
    func caseInsensitivity() throws {
        let op = try EtcdCommandParser.parse("GET mykey")
        guard case .get(let key, _, _, _, _, _) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(key == "mykey")
    }

    @Test("Mixed case commands")
    func mixedCase() throws {
        let op = try EtcdCommandParser.parse("GeT mykey")
        guard case .get(let key, _, _, _, _, _) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(key == "mykey")
    }
}

// MARK: - Lease ID Parsing

@Suite("EtcdCommandParser - Lease ID Parsing")
struct EtcdCommandParserLeaseIdTests {
    @Test("Decimal lease ID")
    func decimalLeaseId() throws {
        let result = try EtcdCommandParser.parseLeaseId("12345")
        #expect(result == 12345)
    }

    @Test("Hex lease ID with 0x prefix")
    func hexLeaseIdWithPrefix() throws {
        let result = try EtcdCommandParser.parseLeaseId("0x1234abcd")
        #expect(result == 0x1234abcd)
    }

    @Test("Hex lease ID with 0X prefix")
    func hexLeaseIdWithUpperPrefix() throws {
        let result = try EtcdCommandParser.parseLeaseId("0X1234ABCD")
        #expect(result == 0x1234abcd)
    }

    @Test("Hex lease ID without prefix (auto-detected)")
    func hexLeaseIdAutoDetected() throws {
        let result = try EtcdCommandParser.parseLeaseId("abcdef")
        #expect(result == 0xabcdef)
    }

    @Test("Invalid lease ID throws")
    func invalidLeaseId() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parseLeaseId("not-a-number")
        }
    }

    @Test("Invalid hex lease ID with 0x prefix throws")
    func invalidHexLeaseId() {
        #expect(throws: EtcdParseError.self) {
            try EtcdCommandParser.parseLeaseId("0xZZZZ")
        }
    }
}
