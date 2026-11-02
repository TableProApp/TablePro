//
//  CassandraObjectQueries.swift
//  TableProCassandraCore
//

import Foundation
import TableProSQLGrammar
import TableProSQLQuoting

// The DDL built here is what the source pane shows and export writes, so it has to run as CQL when pasted back.
public enum CassandraObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        SQLQuoting.stringLiteralBody(value)
    }

    public static func quote(_ identifier: String) -> String {
        SQLQuoting.identifier(identifier)
    }

    // An empty comment is the option's default, which removes it. A materialized view's comment is not read back.
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

    // The driver renders a list cell as its elements joined by ", ", which cannot be split back when an element
    // holds one, so list columns are read through `toJson`.
    public static func functionList(keyspace: String) -> String {
        """
        SELECT function_name, toJson(argument_names), toJson(argument_types), return_type, language, body,
            called_on_null_input
        FROM system_schema.functions
        WHERE keyspace_name = '\(escapeLiteral(keyspace))'
        """
    }

    public static func aggregateList(keyspace: String) -> String {
        """
        SELECT aggregate_name, toJson(argument_types), return_type, state_func, state_type, final_func
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

    // The elements of a list column read through `toJson`. An empty list is null in Cassandra. Nil when the text
    // is not a JSON list of strings.
    public static func jsonList(_ text: String?) -> [String]? {
        guard let text, text.trimmingCharacters(in: .whitespacesAndNewlines) != "null" else { return [] }
        return try? JSONDecoder().decode([String].self, from: Data(text.utf8))
    }

    // Nil when an argument type is not one CQL type, so the routine gets no definition.
    public static func signature(
        argumentNames: [String],
        argumentTypes: [String],
        quotingNames: Bool = false
    ) -> String? {
        guard argumentTypes.allSatisfy(isSingleType) else { return nil }
        let parts = argumentTypes.enumerated().map { index, type -> String in
            guard index < argumentNames.count, !argumentNames[index].isEmpty else { return type }
            return "\(quotingNames ? quote(argumentNames[index]) : argumentNames[index]) \(type)"
        }
        return "(\(parts.joined(separator: ", ")))"
    }

    // A type is catalog text spliced into DDL, so it has to be one CQL type, `map<text, int>` included.
    public static func isSingleType(_ type: String) -> Bool {
        SQLExpressionFragment.isSingleType(type, databaseTypeId: "Cassandra")
    }

    // Catalog text spliced into DDL, such as a view's WHERE clause, has to be one CQL expression.
    public static func isSingleExpression(_ text: String) -> Bool {
        SQLExpressionFragment.isSingleExpression(text, databaseTypeId: "Cassandra")
    }

    // Nil when the return type or the language is not one CQL token run the statement can hold.
    public static func functionDefinition(
        keyspace: String,
        name: String,
        signature: String,
        returnType: String?,
        language: String?,
        body: String?,
        calledOnNullInput: Bool
    ) -> String? {
        let returnType = returnType ?? "text"
        let language = language ?? "java"
        guard isSingleType(returnType), isSingleExpression(language) else { return nil }
        let nullBehaviour = calledOnNullInput ? "CALLED ON NULL INPUT" : "RETURNS NULL ON NULL INPUT"
        // A body may hold `$$` when it was created as a `'…'` string, which a `$$` literal cannot carry.
        let source = SQLQuoting.dollarQuoted(body ?? "") ?? SQLQuoting.stringLiteral(body ?? "")
        return """
            CREATE OR REPLACE FUNCTION \(quote(keyspace)).\(quote(name))\(signature)
                \(nullBehaviour)
                RETURNS \(returnType)
                LANGUAGE \(language)
                AS \(source);
            """
    }

    public static func aggregateDefinition(
        keyspace: String,
        name: String,
        signature: String,
        stateFunction: String?,
        stateType: String?,
        finalFunction: String?
    ) -> String? {
        let stateType = stateType ?? ""
        guard isSingleType(stateType) else { return nil }
        var definition = """
            CREATE OR REPLACE AGGREGATE \(quote(keyspace)).\(quote(name))\(signature)
                SFUNC \(quote(stateFunction ?? ""))
                STYPE \(stateType)
            """
        if let finalFunction, !finalFunction.isEmpty {
            definition += "\n    FINALFUNC \(quote(finalFunction))"
        }
        return definition + ";"
    }

    // The driver renders the options map as `{class: com.example.Audit}`.
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
