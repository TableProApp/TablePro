import Foundation
import TableProGoogleCloud

public enum SpannerDialect: String, Sendable, Codable {
    case googleSQL
    case postgreSQL

    public init(databaseDialect: String?) {
        let normalized = databaseDialect?.trimmingCharacters(in: .whitespaces).uppercased()
        self = normalized == "POSTGRESQL" ? .postgreSQL : .googleSQL
    }

    public var defaultSchema: String {
        switch self {
        case .googleSQL: ""
        case .postgreSQL: "public"
        }
    }

    public var textCastType: String {
        switch self {
        case .googleSQL: "STRING"
        case .postgreSQL: "TEXT"
        }
    }

    public var placeholderLexicon: SQLPlaceholderLexicon {
        switch self {
        case .googleSQL: .googleSQL
        case .postgreSQL: .postgreSQL
        }
    }

    public func placeholder(_ index: Int) -> String {
        switch self {
        case .googleSQL: "@p\(index)"
        case .postgreSQL: "$\(index)"
        }
    }

    public func quoteIdentifier(_ name: String) -> String {
        switch self {
        case .googleSQL:
            GoogleSQLLiteral.quotedIdentifier(name)
        case .postgreSQL:
            "\"" + name.replacingOccurrences(of: "\u{0}", with: "").replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    public func quotedString(_ value: String) -> String {
        "'" + escapedStringBody(value) + "'"
    }

    public func escapedStringBody(_ value: String) -> String {
        switch self {
        case .googleSQL:
            GoogleSQLLiteral.escapedStringBody(value)
        case .postgreSQL:
            value.replacingOccurrences(of: "\u{0}", with: "").replacingOccurrences(of: "'", with: "''")
        }
    }

    public func qualifiedName(schema: String, name: String) -> String {
        guard !schema.isEmpty, schema != defaultSchema else { return quoteIdentifier(name) }
        return quoteIdentifier(schema) + "." + quoteIdentifier(name)
    }

    public func isSystemSchema(_ name: String) -> Bool {
        Self.systemSchemas.contains(name.uppercased())
    }

    private static let systemSchemas: Set<String> = ["INFORMATION_SCHEMA", "SPANNER_SYS", "PG_CATALOG"]
}
