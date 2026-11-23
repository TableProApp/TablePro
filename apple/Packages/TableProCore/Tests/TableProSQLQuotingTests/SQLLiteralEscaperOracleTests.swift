import Foundation
import TableProSQLQuoting
import Testing

// The scalar loop SQLQuoting ran before it moved to a byte scan, kept as the oracle the byte scan must match.
private enum ScalarLoopOracle {
    static func body(_ value: String, escapes: SQLStringEscapes) -> String {
        var output = String.UnicodeScalarView()
        append(value, escapes: escapes, to: &output)
        return String(output)
    }

    private static func append(_ value: String, escapes: SQLStringEscapes, to output: inout String.UnicodeScalarView) {
        if escapes == .sqlServer {
            let scalars = Array(body(value, escapes: .standard).unicodeScalars)
            for (index, scalar) in scalars.enumerated() {
                output.append(scalar)
                guard scalar == "\\", index + 1 < scalars.count else { continue }
                if scalars[index + 1] == "\n" {
                    output.append(contentsOf: "\\\n".unicodeScalars)
                } else if scalars[index + 1] == "\r" {
                    output.append("\\")
                    if index + 2 < scalars.count, scalars[index + 2] == "\n" {
                        output.append(contentsOf: "\r\n".unicodeScalars)
                    }
                }
            }
            return
        }
        let scalars = Array(value.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            switch (scalar, escapes) {
            case (_, .googleSQL):
                appendGoogleSQL(scalar, to: &output)
            case ("'", _):
                output.append(contentsOf: "''".unicodeScalars)
            case ("\0", .standard):
                continue
            case (_, .standard):
                output.append(scalar)
            case ("\\", _):
                output.append(contentsOf: #"\\"#.unicodeScalars)
            case ("\0", .backslash) where index + 1 < scalars.count && ("0"..."9").contains(scalars[index + 1]):
                output.append(contentsOf: #"\x00"#.unicodeScalars)
            case ("\0", _):
                output.append(contentsOf: #"\0"#.unicodeScalars)
            case ("\u{08}", .mysql):
                output.append(contentsOf: #"\b"#.unicodeScalars)
            case ("\n", .mysql):
                output.append(contentsOf: #"\n"#.unicodeScalars)
            case ("\r", .mysql):
                output.append(contentsOf: #"\r"#.unicodeScalars)
            case ("\t", .mysql):
                output.append(contentsOf: #"\t"#.unicodeScalars)
            case ("\u{1A}", .mysql):
                output.append(contentsOf: #"\Z"#.unicodeScalars)
            default:
                output.append(scalar)
            }
        }
    }

    private static let hexDigits = Array("0123456789abcdef".unicodeScalars)

    private static func appendGoogleSQL(_ scalar: Unicode.Scalar, to output: inout String.UnicodeScalarView) {
        switch scalar {
        case "\\", "'", "\"", "`":
            output.append("\\")
            output.append(scalar)
        case "\n":
            output.append(contentsOf: #"\n"#.unicodeScalars)
        case "\r":
            output.append(contentsOf: #"\r"#.unicodeScalars)
        case "\t":
            output.append(contentsOf: #"\t"#.unicodeScalars)
        case _ where scalar.value < 0x20 || scalar.value == 0x7F:
            output.append(contentsOf: #"\x"#.unicodeScalars)
            output.append(hexDigits[Int(scalar.value >> 4)])
            output.append(hexDigits[Int(scalar.value & 0xF)])
        default:
            output.append(scalar)
        }
    }
}

private let allEscapes: [SQLStringEscapes] = [.standard, .sqlServer, .backslash, .mysql, .googleSQL]

private let triggers: [String] = [
    "'", "\0", "\\", "\n", "\r", "\t", "\u{08}", "\u{1A}", "\"", "`", "\u{01}", "\u{1F}", "\u{7F}",
]

private func generatedValues() -> [String] {
    let scalars: [Unicode.Scalar] = [
        "'", "\"", "`", "\\", "%", "_", "\n", "\r", "\t", "\0", "1", "9", "a", " ", "\u{301}", "\u{200D}",
        "\u{1F3FB}", "\u{1A}", "\u{08}", "\u{2028}", "\u{85}", "\u{7F}", "\u{01}", "\u{E9}", "\u{65E5}",
    ]
    var state: UInt64 = 0xE5_CA_9E
    return (0..<1_500).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let length = Int((state >> 40) % 16)
        var text = String.UnicodeScalarView()
        for _ in 0..<length {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            text.append(scalars[Int((state >> 33) % UInt64(scalars.count))])
        }
        return String(text)
    }
}

private func handPickedValues() -> [String] {
    var values = [
        "", "plain text", "0", "12.5", "\0" + "1", "a\0" + "9b", "\0", "\\\n", "\\\r\n", "\\\r", "a\\\0\nb",
        "\r\n", "\r", "x'\u{301}y", "'\u{301}", "\u{1F468}\u{200D}\u{1F469}'s", "emoji 🎉 'quoted'",
        String(repeating: "clean text ", count: 400), String(repeating: "'", count: 300),
    ]
    for trigger in triggers {
        values += [trigger, trigger + "abc", "abc" + trigger, "ab" + trigger + "cd", trigger + trigger]
    }
    return values
}

struct SQLLiteralEscaperOracleTests {
    @Test("The byte scan writes what the scalar loop wrote, for every escape mode", arguments: allEscapes)
    func matchesScalarLoop(escapes: SQLStringEscapes) {
        for value in handPickedValues() + generatedValues() {
            let expected = ScalarLoopOracle.body(value, escapes: escapes)
            let body = SQLQuoting.stringLiteralBody(value, escapes: escapes)
            let literal = SQLQuoting.stringLiteral(value, escapes: escapes)
            #expect(Array(body.unicodeScalars) == Array(expected.unicodeScalars), "\(value.debugDescription)")
            #expect(
                Array(literal.unicodeScalars) == Array(("'" + expected + "'").unicodeScalars),
                "\(value.debugDescription)"
            )
        }
    }

    @Test("A bridged string with a lone surrogate escapes as the scalar loop read it", arguments: allEscapes)
    func loneSurrogate(escapes: SQLStringEscapes) {
        let units: [unichar] = [0x61, 0xD800, 0x27, 0x62]
        let value = NSString(characters: units, length: units.count) as String
        let expected = ScalarLoopOracle.body(value, escapes: escapes)
        #expect(
            Array(SQLQuoting.stringLiteralBody(value, escapes: escapes).unicodeScalars)
                == Array(expected.unicodeScalars)
        )
    }

    @Test("A value with nothing to escape comes back unchanged")
    func cleanValueUnchanged() {
        for escapes in allEscapes {
            #expect(SQLQuoting.stringLiteralBody("Hà Nội 2026", escapes: escapes) == "Hà Nội 2026")
            #expect(SQLQuoting.stringLiteral("", escapes: escapes) == "''")
        }
        #expect(SQLQuoting.stringLiteralBody("\0\0", escapes: .standard).isEmpty)
        #expect(SQLQuoting.stringLiteral("\0", escapes: .sqlServer) == "''")
    }
}
