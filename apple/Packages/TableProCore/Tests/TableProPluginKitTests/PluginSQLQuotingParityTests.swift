@testable import TableProPluginKit
import TableProSQLQuoting
import Testing

// PluginKit cannot link TableProSQLQuoting, so it carries the same rules; this holds them to one output.
struct PluginSQLQuotingParityTests {
    private static let scalars: [Unicode.Scalar] = [
        "'", "\"", "`", "\\", "%", "_", "\n", "\r", "\t", "\0", "1", "a", " ", "\u{301}", "\u{200D}", "\u{1F3FB}",
        "\u{1A}", "\u{08}", "\u{2028}", "\u{85}",
    ]

    private static func values() -> [String] {
        var state: UInt64 = 0xB3_55
        return (0..<400).map { _ in
            var text = String.UnicodeScalarView()
            for _ in 0..<12 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                text.append(scalars[Int((state >> 33) % UInt64(scalars.count))])
            }
            return String(text)
        }
    }

    @Test("PluginKit quotes exactly as TableProSQLQuoting does")
    func sameOutput() {
        for value in Self.values() {
            #expect(PluginSQLQuoting.identifier(value) == SQLQuoting.identifier(value))
            #expect(PluginSQLQuoting.stringLiteralBody(value) == SQLQuoting.stringLiteralBody(value))
            #expect(
                PluginSQLQuoting.stringLiteralBody(value, escapes: .backslash)
                    == SQLQuoting.stringLiteralBody(value, escapes: .backslash)
            )
            #expect(
                PluginSQLQuoting.stringLiteralBody(value, escapes: .googleSQL)
                    == SQLQuoting.stringLiteralBody(value, escapes: .googleSQL)
            )
            #expect(PluginSQLQuoting.likePattern(value) == SQLQuoting.likePattern(value))
            #expect(PluginSQLQuoting.lineCommentText(value) == SQLQuoting.lineCommentText(value))
        }
    }

    // The generator above almost never makes a value with nothing to escape, which is the export's common case.
    @Test("PluginKit quotes clean values and single triggers exactly as TableProSQLQuoting does")
    func sameOutputForCleanValues() {
        var values = ["", "plain", "Hà Nội", "🎉 party", "12345", String(repeating: "abc ", count: 300)]
        for trigger in ["'", "\0", "\\", "\n", "\r", "\t", "\"", "`", "\u{7F}", "\u{01}"] {
            values += [trigger, "a" + trigger, trigger + "b", "a" + trigger + "b", trigger + "1"]
        }
        for value in values {
            #expect(PluginSQLQuoting.stringLiteral(value) == SQLQuoting.stringLiteral(value))
            #expect(PluginSQLQuoting.stringLiteralBody(value) == SQLQuoting.stringLiteralBody(value))
            #expect(
                PluginSQLQuoting.stringLiteral(value, escapes: .backslash)
                    == SQLQuoting.stringLiteral(value, escapes: .backslash)
            )
            #expect(
                PluginSQLQuoting.stringLiteral(value, escapes: .googleSQL)
                    == SQLQuoting.stringLiteral(value, escapes: .googleSQL)
            )
        }
    }
}
