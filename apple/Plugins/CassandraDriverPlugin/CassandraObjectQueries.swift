//
//  CassandraObjectQueries.swift
//  CassandraDriverPlugin
//

import Foundation

/// Cassandra has user-defined functions and aggregates, and triggers that are a Java class name
/// rather than a body. The DDL built here is what the source pane shows and what export writes, so it has to run
/// as CQL when pasted back: names are quoted, and a trigger names its class as a string literal.
public enum CassandraObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''", options: .literal)
    }

    public static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"", options: .literal) + "\""
    }

    /// A table's comment is one of its options, and an empty string is the option's default, so
    /// that is what removes it. Materialized views are left out: their comment is not read back.
    public static func tableCommentStatement(keyspace: String, table: String, objectType: String, comment: String?) -> String? {
        guard objectType.uppercased() == "TABLE" else { return nil }
        return "ALTER TABLE \(quote(keyspace)).\(quote(table)) WITH comment = '\(escapeLiteral(comment ?? ""))'"
    }

    public static func tableComment(keyspace: String, table: String) -> String {
        """
        SELECT comment FROM system_schema.tables
        WHERE keyspace_name = '\(escapeLiteral(keyspace))' AND table_name = '\(escapeLiteral(table))'
        """
    }

    public static func functionList(keyspace: String) -> String {
        """
        SELECT function_name, argument_names, argument_types, return_type, language, body, called_on_null_input
        FROM system_schema.functions
        WHERE keyspace_name = '\(escapeLiteral(keyspace))'
        """
    }

    public static func aggregateList(keyspace: String) -> String {
        """
        SELECT aggregate_name, argument_types, return_type, state_func, state_type, final_func
        FROM system_schema.aggregates
        WHERE keyspace_name = '\(escapeLiteral(keyspace))'
        """
    }

    public static func triggerList(keyspace: String, table: String?) -> String {
        let tablePredicate = table.map { " AND table_name = '\(escapeLiteral($0))'" } ?? ""
        return """
            SELECT trigger_name, table_name, keyspace_name, options
            FROM system_schema.triggers
            WHERE keyspace_name = '\(escapeLiteral(keyspace))'\(tablePredicate)
            ALLOW FILTERING
            """
    }

    public static func signature(argumentNames: String?, argumentTypes: String?, quotingNames: Bool = false) -> String {
        let names = Self.names(of: argumentNames)
        let types = Self.types(of: argumentTypes)
        guard !types.isEmpty else { return "()" }
        let parts = types.enumerated().map { index, type -> String in
            guard index < names.count, !names[index].isEmpty else { return type }
            return "\(quotingNames ? quote(names[index]) : names[index]) \(type)"
        }
        return "(\(parts.joined(separator: ", ")))"
    }

    /// The driver renders a CQL list as `[a, b]`: the elements joined by ", ", nothing quoted or trimmed. A name is
    /// raw text, so one holding ", " reads as two and the list comes back longer than its types.
    public static func names(of value: String?) -> [String] {
        guard let body = listBody(value) else { return [] }
        return body.components(separatedBy: ", ")
    }

    /// A type is CQL as the server spells it, `frozen<map<text, int>>` or `frozen<"My, Type">`, so the list splits
    /// only at a ", " outside angle brackets, parentheses and quoted names.
    public static func types(of value: String?) -> [String] {
        guard let body = listBody(value) else { return [] }
        var items: [String] = []
        var current = ""
        var depth = 0
        var isQuoted = false
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            let next = body.index(after: index)
            if character == "\"" {
                isQuoted.toggle()
            } else if !isQuoted {
                switch character {
                case "<", "(":
                    depth += 1
                case ">", ")":
                    depth -= 1
                case "," where depth == 0 && next < body.endIndex && body[next] == " ":
                    items.append(current)
                    current = ""
                    index = body.index(after: next)
                    continue
                default:
                    break
                }
            }
            current.append(character)
            index = next
        }
        items.append(current)
        return items
    }

    private static func listBody(_ value: String?) -> String? {
        guard let value else { return nil }
        let body = value.hasPrefix("[") && value.hasSuffix("]") ? String(value.dropFirst().dropLast()) : value
        return body.isEmpty ? nil : body
    }

    public static func functionDefinition(
        keyspace: String,
        name: String,
        signature: String,
        returnType: String?,
        language: String?,
        body: String?,
        calledOnNullInput: Bool
    ) -> String {
        let nullBehaviour = calledOnNullInput ? "CALLED ON NULL INPUT" : "RETURNS NULL ON NULL INPUT"
        return """
            CREATE OR REPLACE FUNCTION \(quote(keyspace)).\(quote(name))\(signature)
                \(nullBehaviour)
                RETURNS \(returnType ?? "text")
                LANGUAGE \(language ?? "java")
                AS $$\(body ?? "")$$;
            """
    }

    public static func aggregateDefinition(
        keyspace: String,
        name: String,
        signature: String,
        stateFunction: String?,
        stateType: String?,
        finalFunction: String?
    ) -> String {
        var definition = """
            CREATE OR REPLACE AGGREGATE \(quote(keyspace)).\(quote(name))\(signature)
                SFUNC \(quote(stateFunction ?? ""))
                STYPE \(stateType ?? "")
            """
        if let finalFunction, !finalFunction.isEmpty {
            definition += "\n    FINALFUNC \(quote(finalFunction))"
        }
        return definition + ";"
    }

    /// `system_schema.triggers.options` is a map whose `class` entry names the Java class; the driver renders the
    /// map as `{class: com.example.Audit}`.
    public static func triggerClass(fromOptions options: String?) -> String? {
        guard let options else { return nil }
        let body = options.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
        for pair in body.components(separatedBy: ", ") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "class" else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    public static func triggerDefinition(keyspace: String, table: String, name: String, className: String) -> String {
        """
        CREATE TRIGGER \(quote(name)) ON \(quote(keyspace)).\(quote(table))
            USING '\(escapeLiteral(className))';
        """
    }
}
