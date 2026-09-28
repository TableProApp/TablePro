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
        value.replacingOccurrences(of: "'", with: "''")
    }

    public static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
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
        let names = elements(of: argumentNames)
        let types = elements(of: argumentTypes)
        guard !types.isEmpty else { return "()" }
        let parts = types.enumerated().map { index, type -> String in
            guard index < names.count, !names[index].isEmpty else { return type }
            return "\(quotingNames ? quote(names[index]) : names[index]) \(type)"
        }
        return "(\(parts.joined(separator: ", ")))"
    }

    /// The driver renders a CQL list as `[a, b]`, with no quotes, and an element can itself hold a comma, as the
    /// type `frozen<map<text, int>>` does. So the list splits only at commas outside angle brackets.
    public static func elements(of value: String?) -> [String] {
        guard let value else { return [] }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let body = trimmed.hasPrefix("[") && trimmed.hasSuffix("]") ? String(trimmed.dropFirst().dropLast()) : trimmed
        var items: [String] = []
        var current = ""
        var depth = 0
        for character in body {
            switch character {
            case "<", "(":
                depth += 1
            case ">", ")":
                depth -= 1
            case "," where depth == 0:
                items.append(current)
                current = ""
                continue
            default:
                break
            }
            current.append(character)
        }
        items.append(current)
        return items
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }
            .filter { !$0.isEmpty }
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
