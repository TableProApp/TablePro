import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Connection URL Parser - TiDB")
struct ConnectionURLParserTiDBTests {
    @Test("Full tidb URL with default port")
    func testFullURLDefaultPort() {
        let result = ConnectionURLParser.parse("tidb://user:pass@host:4000/test")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .tidb)
        #expect(parsed.host == "host")
        #expect(parsed.port == nil)
        #expect(parsed.database == "test")
        #expect(parsed.username == "user")
        #expect(parsed.password == "pass")
    }

    @Test("Case-insensitive TiDB scheme")
    func testCaseInsensitiveScheme() {
        let result = ConnectionURLParser.parse("TiDB://user@host/db")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .tidb)
        #expect(parsed.host == "host")
        #expect(parsed.username == "user")
    }

    @Test("TiDB non-default port preserved")
    func testNonDefaultPortPreserved() {
        let result = ConnectionURLParser.parse("tidb://user:pass@host:4001/db")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .tidb)
        #expect(parsed.port == 4_001)
        #expect(parsed.host == "host")
        #expect(parsed.database == "db")
    }
}
