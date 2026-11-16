import Foundation

// A dump drops each object before creating it, and has to restore into a schema that never had it. 23ai takes
// `DROP ... IF EXISTS`; before it only a block that ignores the object's own "does not exist" error does.
public enum OracleDropStatements {
    public enum Object: Sendable, CaseIterable {
        case table
        case view
        case materializedView
        case trigger

        var keyword: String {
            switch self {
            case .table: "TABLE"
            case .view: "VIEW"
            case .materializedView: "MATERIALIZED VIEW"
            case .trigger: "TRIGGER"
            }
        }

        // ORA-00942 table or view, ORA-12003 materialized view, ORA-04080 trigger: "does not exist".
        public var missingObjectCode: Int {
            switch self {
            case .table, .view: -942
            case .materializedView: -12_003
            case .trigger: -4_080
            }
        }
    }

    // An unknown release gets the block, which every release runs.
    public static func drop(
        _ object: Object,
        name: String,
        schema: String?,
        currentSchema: String?,
        release: OracleServerRelease?
    ) -> String {
        let target = target(name: name, schema: schema, currentSchema: currentSchema)
        if let release, release.hasDropIfExists {
            return "DROP \(object.keyword) IF EXISTS \(target)"
        }
        return ignoringMissingObject("DROP \(object.keyword) \(target)", code: object.missingObjectCode)
    }

    // Unqualified in the current schema, so the dump restores into a schema of another name.
    static func target(name: String, schema: String?, currentSchema: String?) -> String {
        guard let owner = schema?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty,
              owner != currentSchema
        else {
            return OracleSchemaQueries.quoteIdentifier(name)
        }
        return "\(OracleSchemaQueries.quoteIdentifier(owner)).\(OracleSchemaQueries.quoteIdentifier(name))"
    }

    static func ignoringMissingObject(_ statement: String, code: Int) -> String {
        """
        BEGIN
          EXECUTE IMMEDIATE '\(OracleSchemaQueries.escapeLiteral(statement))';
        EXCEPTION
          WHEN OTHERS THEN
            IF SQLCODE != \(code) THEN
              RAISE;
            END IF;
        END;
        """
    }
}
