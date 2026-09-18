//
//  PostgreSQLViewDefinition.swift
//  PostgreSQLDriverPlugin
//
//  Rebuilds the CREATE statement of a view or materialized view from the catalog. Pure, so it is
//  testable without a server.
//

import Foundation

public enum PostgreSQLViewDefinition {
    public enum Kind: Equatable, Sendable {
        case view
        case materializedView
    }

    /// Everything the statement is rebuilt from. `pg_get_viewdef` returns the query alone, so the
    /// view's options, its check option, and a materialized view's access method and tablespace
    /// each come from their own catalog column.
    public struct CatalogRow: Equatable, Sendable {
        public let kind: Kind
        public let query: String
        public let options: [String]
        public let accessMethod: String?
        public let tablespace: String?

        public init(kind: Kind, query: String, options: [String], accessMethod: String?, tablespace: String?) {
            self.kind = kind
            self.query = query
            self.options = options
            self.accessMethod = accessMethod
            self.tablespace = tablespace
        }
    }

    /// Run with `search_path` narrowed first (see `qualifiedReadPrefix`). `pg_get_viewdef` writes a
    /// table name bare whenever the reading session could resolve it without its schema, and the
    /// scoped connection this runs on has its path set to the view's own schema, so the body came
    /// back naming `orders` rather than `sales.orders`. Run anywhere else, that text silently bound
    /// to whichever `orders` the new session found first.
    public static func catalogQuery(name: String, schema: String) -> String {
        """
        SELECT
            c.relkind::text,
            pg_catalog.pg_get_viewdef(c.oid, true),
            c.reloptions::text,
            am.amname::text,
            ts.spcname::text
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_catalog.pg_am am ON am.oid = c.relam
        LEFT JOIN pg_catalog.pg_tablespace ts ON ts.oid = c.reltablespace
        WHERE c.relkind IN ('v', 'm')
          AND n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
          AND c.relname = \(PostgreSQLObjectQueries.quoteLiteral(name))
        """
    }

    /// `SET LOCAL` lasts only as long as the transaction it runs in. Sent in the same query string
    /// as the read, the pair is one implicit transaction, so the path is back to what it was as
    /// soon as the read returns. Inside a transaction the caller already holds, it would last until
    /// that transaction ends, which is why the driver wraps the read in a savepoint there.
    ///
    /// `pg_catalog` rather than an empty path: PostgreSQL 9.1 rejects `''` ("schema "" does not
    /// exist"), and `pg_catalog` is searched implicitly anyway, so every user relation is still
    /// written with its schema. Measured identical output on 9.2, 9.3, 9.6 and 17.
    public static let qualifiedReadPrefix = "SET LOCAL search_path = pg_catalog; "

    public static func parse(row: [String?]) -> CatalogRow? {
        guard row.count >= 5,
              let relkind = row[0],
              let query = row[1],
              let kind = kind(forRelkind: relkind)
        else { return nil }
        return CatalogRow(
            kind: kind,
            query: query,
            options: PostgreSQLTextArray.values(row[2]),
            accessMethod: row[3]?.nilIfBlank,
            tablespace: row[4]?.nilIfBlank
        )
    }

    public static func kind(forRelkind relkind: String) -> Kind? {
        switch relkind {
        case "v": return .view
        case "m": return .materializedView
        default: return nil
        }
    }

    public static func statement(name: String, schema: String, row: CatalogRow) -> String {
        let target = PostgreSQLObjectQueries.qualifiedName(schema: schema, name: name)
        let body = trimmedQuery(row.query)
        switch row.kind {
        case .view:
            return viewStatement(target: target, body: body, options: row.options)
        case .materializedView:
            return materializedViewStatement(target: target, body: body, row: row)
        }
    }

    /// `CREATE OR REPLACE VIEW` resets every option the statement leaves out, so running a
    /// definition that dropped `security_barrier`, `security_invoker` or the check option quietly
    /// turned a restricted view into an unrestricted one. The check option is stored as a
    /// reloption but written as its own clause after the query, the way `pg_dump` writes it.
    private static func viewStatement(target: String, body: String, options: [String]) -> String {
        let parsed = options.map(splitOption)
        let checkOption = parsed.first { $0.name == "check_option" }?.value
        let storage = parsed.filter { $0.name != "check_option" }
        var header = "CREATE OR REPLACE VIEW \(target)"
        if let withClause = withClause(storage) {
            header += " \(withClause)"
        }
        var statement = "\(header) AS\n\(body)"
        if let checkOption, !checkOption.isEmpty {
            statement += "\n  WITH \(checkOption.uppercased()) CHECK OPTION"
        }
        return statement + ";"
    }

    /// The access method is written only when it is not the default, because `USING` does not
    /// exist before PostgreSQL 12 and `heap` is what every server creates without it.
    private static func materializedViewStatement(target: String, body: String, row: CatalogRow) -> String {
        var header = "CREATE MATERIALIZED VIEW \(target)"
        if let accessMethod = row.accessMethod, accessMethod != "heap" {
            header += " USING \(PostgreSQLObjectQueries.quoteIdentifier(accessMethod))"
        }
        if let withClause = withClause(row.options.map(splitOption)) {
            header += " \(withClause)"
        }
        if let tablespace = row.tablespace {
            header += " TABLESPACE \(PostgreSQLObjectQueries.quoteIdentifier(tablespace))"
        }
        return "\(header) AS\n\(body);"
    }

    private static func withClause(_ options: [(name: String, value: String)]) -> String? {
        guard !options.isEmpty else { return nil }
        let rendered = options.map { "\($0.name)=\(PostgreSQLObjectQueries.quoteLiteral($0.value))" }
        return "WITH (\(rendered.joined(separator: ", ")))"
    }

    private static func splitOption(_ option: String) -> (name: String, value: String) {
        guard let separator = option.firstIndex(of: "=") else { return (option, "") }
        return (String(option[..<separator]), String(option[option.index(after: separator)...]))
    }

    /// `pg_get_viewdef` ends the query with its own semicolon, and the check option has to go
    /// before it.
    private static func trimmedQuery(_ query: String) -> String {
        var trimmed = Substring(query)
        while let last = trimmed.last, last.isWhitespace || last == ";" {
            trimmed = trimmed.dropLast()
        }
        return String(trimmed)
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
