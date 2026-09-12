import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Connection URL Parser - OceanBase")
struct ConnectionURLParserOceanBaseTests {
    @Test("Full oceanbase URL with default port")
    func testFullURLDefaultPort() {
        let result = ConnectionURLParser.parse("oceanbase://root%40sys:pass@host:2881/test")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .oceanbase)
        #expect(parsed.host == "host")
        #expect(parsed.port == nil)
        #expect(parsed.database == "test")
        #expect(parsed.username == "root@sys")
        #expect(parsed.password == "pass")
    }

    @Test("Case-insensitive OceanBase scheme")
    func testCaseInsensitiveScheme() {
        let result = ConnectionURLParser.parse("OceanBase://root%40sys@host/db")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .oceanbase)
        #expect(parsed.host == "host")
        #expect(parsed.username == "root@sys")
    }

    @Test("OceanBase non-default port preserved")
    func testNonDefaultPortPreserved() {
        let result = ConnectionURLParser.parse("oceanbase://root%40sys:pass@host:2883/db")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .oceanbase)
        #expect(parsed.port == 2_883)
        #expect(parsed.host == "host")
        #expect(parsed.database == "db")
    }
}
