import Foundation

enum HanaSQL {
    static func quoteIdentifier(_ name: String) -> String {
        "\"\(doubling("\"", in: name))\""
    }

    static func quoteLiteral(_ value: String) -> String {
        "N'\(escapeLiteralBody(value))'"
    }

    static func escapeLiteralBody(_ value: String) -> String {
        doubling("'", in: value, dropping: "\0")
    }

    static func qualifiedName(schema: String, name: String) -> String {
        "\(quoteIdentifier(schema)).\(quoteIdentifier(name))"
    }

    static func commentStatement(objectType: String, qualifiedName: String, comment: String?) -> String? {
        let keyword: String
        switch objectType.uppercased() {
        case "TABLE":
            keyword = "TABLE"
        case "VIEW":
            keyword = "VIEW"
        default:
            return nil
        }
        guard let comment, !comment.isEmpty else {
            return "COMMENT ON \(keyword) \(qualifiedName) IS NULL"
        }
        return "COMMENT ON \(keyword) \(qualifiedName) IS \(quoteLiteral(comment))"
    }

    private static func doubling(_ quote: Unicode.Scalar, in text: String, dropping removed: Unicode.Scalar? = nil) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar != removed {
            if scalar == quote { escaped.append(scalar) }
            escaped.append(scalar)
        }
        return String(escaped)
    }
}
