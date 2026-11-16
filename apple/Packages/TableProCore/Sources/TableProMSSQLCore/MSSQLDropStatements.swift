import Foundation

// T-SQL has no DROP ROUTINE: a procedure, a function and a CLR aggregate each have their own verb.
public enum MSSQLDropStatements {
    public static func routine(schema: String, name: String, isFunction: Bool, signature: String?) -> String {
        let keyword = switch (isFunction, MSSQLRoutineSignature.namesAggregate(signature)) {
        case (true, true): "AGGREGATE"
        case (true, false): "FUNCTION"
        case (false, _): "PROCEDURE"
        }
        return "DROP \(keyword) IF EXISTS \(MSSQLSchemaQueries.bracketed(schema: schema, table: name))"
    }

    // A DML trigger lives in its table's schema and is named without the table.
    public static func trigger(schema: String, name: String) -> String {
        "DROP TRIGGER \(MSSQLSchemaQueries.bracketed(schema: schema, table: name))"
    }
}
