import Foundation

public enum GoogleSQLLiteral {
    public static func quotedString(_ value: String) -> String {
        "'" + escapedStringBody(value) + "'"
    }

    public static func escapedStringBody(_ value: String) -> String {
        escaped(value, escapingBacktick: false)
    }

    public static func quotedIdentifier(_ name: String) -> String {
        "`" + escaped(name, escapingBacktick: true) + "`"
    }

    public static func bytesLiteral(_ data: Data) -> String {
        "FROM_BASE64('" + data.base64EncodedString() + "')"
    }

    public static func likePatternBody(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if likeMetacharacters.contains(scalar) {
                result.append("\\")
            }
            result.append(scalar)
        }
        return String(result)
    }

    private static let likeMetacharacters: Set<Unicode.Scalar> = ["\\", "%", "_"]
    private static let hexDigits = Array("0123456789abcdef".unicodeScalars)

    private static func escaped(_ value: String, escapingBacktick: Bool) -> String {
        var result = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            appendEscaped(scalar, escapingBacktick: escapingBacktick, to: &result)
        }
        return String(result)
    }

    private static func appendEscaped(
        _ scalar: Unicode.Scalar,
        escapingBacktick: Bool,
        to result: inout String.UnicodeScalarView
    ) {
        switch scalar {
        case "\\", "'", "\"":
            result.append("\\")
            result.append(scalar)
        case "`" where escapingBacktick:
            result.append("\\")
            result.append(scalar)
        case "\n":
            result.append(contentsOf: "\\n".unicodeScalars)
        case "\r":
            result.append(contentsOf: "\\r".unicodeScalars)
        case "\t":
            result.append(contentsOf: "\\t".unicodeScalars)
        default:
            guard isControl(scalar) else {
                result.append(scalar)
                return
            }
            appendHexEscape(scalar, to: &result)
        }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    private static func appendHexEscape(_ scalar: Unicode.Scalar, to result: inout String.UnicodeScalarView) {
        let value = Int(scalar.value)
        result.append("\\")
        result.append("x")
        result.append(hexDigits[value >> 4])
        result.append(hexDigits[value & 0xF])
    }
}
