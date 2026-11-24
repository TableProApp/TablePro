import Foundation

public enum OracleRoutineStatements {
    // ORA-04043: the object does not exist.
    public static let missingObjectCode = -4_043

    // A block on every release, so a dump that drops a routine before creating it also restores into a schema that
    // never had it.
    public static func drop(name: String, schema: String?, currentSchema: String?, isFunction: Bool) -> String {
        let keyword = isFunction ? "FUNCTION" : "PROCEDURE"
        let target = OracleDropStatements.target(name: name, schema: schema, currentSchema: currentSchema)
        return OracleDropStatements.ignoringMissingObject("DROP \(keyword) \(target)", code: missingObjectCode)
    }
}
