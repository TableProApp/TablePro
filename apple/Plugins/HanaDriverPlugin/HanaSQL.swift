import Foundation
import TableProSQLQuoting

enum HanaSQL {
    static func quoteIdentifier(_ name: String) -> String {
        SQLQuoting.identifier(name)
    }

    static func quoteLiteral(_ value: String) -> String {
        "N" + SQLQuoting.stringLiteral(value)
    }

    static func escapeLiteralBody(_ value: String) -> String {
        SQLQuoting.stringLiteralBody(value)
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
}
