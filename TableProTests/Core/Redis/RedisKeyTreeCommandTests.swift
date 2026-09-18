//
//  RedisKeyTreeCommandTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("RedisCommandParser - KEYTREE")
struct RedisKeyTreeCommandTests {
    @Test("KEYTREE with a limit parses to a key tree operation")
    func parsesLimit() throws {
        guard case .keyTree(let pattern, let limit) = try RedisCommandParser.parse("KEYTREE LIMIT 50000") else {
            Issue.record("Expected a keyTree operation")
            return
        }
        #expect(pattern == nil)
        #expect(limit == 50_000)
    }

    @Test("KEYTREE carries a MATCH pattern through")
    func parsesPattern() throws {
        guard case .keyTree(let pattern, _) = try RedisCommandParser.parse("KEYTREE MATCH cache:* LIMIT 10") else {
            Issue.record("Expected a keyTree operation")
            return
        }
        #expect(pattern == "cache:*")
    }

    @Test("KEYTREE without a limit falls back to the row cap")
    func defaultsToRowCap() throws {
        guard case .keyTree(_, let limit) = try RedisCommandParser.parse("KEYTREE") else {
            Issue.record("Expected a keyTree operation")
            return
        }
        #expect(limit == PluginRowLimits.emergencyMax)
    }

    @Test("KEYBROWSE still parses to a key browse operation")
    func keyBrowseUnaffected() throws {
        guard case .keyBrowse(let pattern, let typeScope, let limit, let offset) =
            try RedisCommandParser.parse("KEYBROWSE MATCH session:* TYPE hash LIMIT 100 OFFSET 50") else {
            Issue.record("Expected a keyBrowse operation")
            return
        }
        #expect(pattern == "session:*")
        #expect(typeScope == "hash")
        #expect(limit == 100)
        #expect(offset == 50)
    }
}
