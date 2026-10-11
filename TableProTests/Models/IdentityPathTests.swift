import Foundation
@testable import TablePro
import Testing

struct IdentityPathTests {
    @Test("Components holding neither the separator nor a backslash join unchanged")
    func plainComponentsJoinUnchanged() {
        #expect(IdentityPath.joined(["public", "orders", "audit"], separator: ".") == "public.orders.audit")
        #expect(IdentityPath.joined(["db", "", "users_TABLE"], separator: "|") == "db||users_TABLE")
        #expect(IdentityPath.qualified(name: "orders", schema: "sales") == "sales.orders")
        #expect(IdentityPath.qualified(name: "orders", schema: nil) == "orders")
        #expect(IdentityPath.qualified(name: "orders", schema: "") == "orders")
    }

    @Test("A separator inside a component is escaped")
    func separatorInsideComponentIsEscaped() {
        #expect(IdentityPath.qualified(name: "b.c", schema: "a") == "a.b\\.c")
        #expect(IdentityPath.qualified(name: "c", schema: "a.b") == "a\\.b.c")
        #expect(IdentityPath.joined(["a|b", "c"], separator: "|") == "a\\|b|c")
    }

    @Test("A backslash is escaped too, or a trailing one would swallow the separator")
    func backslashIsEscaped() {
        #expect(IdentityPath.qualified(name: "b", schema: "a\\") == "a\\\\.b")
        #expect(IdentityPath.qualified(name: "a.b", schema: nil) == "a\\.b")
        #expect(IdentityPath.qualified(name: "b", schema: "a\\") != IdentityPath.qualified(name: "a.b", schema: nil))
    }

    @Test("Only the requested separator is escaped")
    func otherSeparatorsStayRaw() {
        #expect(IdentityPath.joined(["a.b", "c"], separator: "|") == "a.b|c")
        #expect(IdentityPath.joined(["a|b", "c"], separator: ".") == "a|b.c")
    }

    @Test("Distinct component lists never share a path", arguments: ["." as Unicode.Scalar, "|" as Unicode.Scalar])
    func distinctListsNeverCollide(separator: Unicode.Scalar) {
        let pieces = ["", "a", "b", "a.b", "a|b", "a\\", "\\", ".", "|", "b.", "b|", "\\."]
        var lists: [[String]] = pieces.map { [$0] }
        for first in pieces {
            for second in pieces {
                lists.append([first, second])
            }
        }
        var seen: [String: [String]] = [:]
        for list in lists {
            let path = IdentityPath.joined(list, separator: separator)
            if let earlier = seen[path] {
                #expect(earlier == list, "\(earlier) and \(list) share \(path)")
            }
            seen[path] = list
        }
    }
}
