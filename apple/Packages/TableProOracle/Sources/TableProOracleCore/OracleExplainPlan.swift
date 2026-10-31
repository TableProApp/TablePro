import Foundation

// The actual plan sets STATISTICS_LEVEL = ALL rather than adding the GATHER_PLAN_STATISTICS hint, which would mean
// rewriting the statement and would displace a hint it already carries.
public enum OracleExplainPlan {
    public static let estimatedVariantId = "estimated"
    public static let actualVariantId = "actual"

    // PLAN_TABLE.STATEMENT_ID is a VARCHAR2(30).
    public static func statementId(_ uuid: UUID = UUID()) -> String {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "")
        return "TP" + hex.prefix(28)
    }

    public static func explainStatement(_ statement: String, statementId: String) -> String {
        "EXPLAIN PLAN SET STATEMENT_ID = '\(statementId)' INTO \(OracleDictionary.planTable) FOR \(bare(statement))"
    }

    public static func planRowsQuery(statementId: String) -> String {
        """
        SELECT \(planColumns.joined(separator: ", "))
        FROM \(OracleDictionary.planTable)
        WHERE STATEMENT_ID = '\(statementId)'
        ORDER BY ID
        """
    }

    public static func deleteStatement(statementId: String) -> String {
        "DELETE FROM \(OracleDictionary.planTable) WHERE STATEMENT_ID = '\(statementId)'"
    }

    // Fails at parse time when a view is out of reach, before the statement runs. V$PARAMETER holds session values.
    public static let actualPlanProbe = """
        SELECT p.VALUE
        FROM \(OracleDictionary.parameterView) p
        WHERE p.NAME = 'statistics_level'
        AND EXISTS (SELECT 1 FROM \(OracleDictionary.sessionView) s WHERE s.SID = SYS_CONTEXT('USERENV', 'SID'))
        AND NOT EXISTS (SELECT 1 FROM \(OracleDictionary.sqlPlanStatisticsView) WHERE 1 = 0)
        """

    // Only Oracle's three levels, so a value read back is never spliced into a statement.
    public static func setStatisticsLevel(_ level: String) -> String? {
        let normalized = level.trimmingCharacters(in: .whitespaces).uppercased()
        guard ["BASIC", "TYPICAL", "ALL"].contains(normalized) else { return nil }
        return "ALTER SESSION SET STATISTICS_LEVEL = \(normalized)"
    }

    public static let gatheringLevel = "ALL"

    // The same lookup DBMS_XPLAN.DISPLAY_CURSOR does for the session's last statement.
    public static let lastCursorPlanQuery = """
        SELECT \(planColumns.map { "p.\($0)" }.joined(separator: ", ")), \
        \(actualColumns.map { "p.\($0)" }.joined(separator: ", "))
        FROM \(OracleDictionary.sqlPlanStatisticsView) p, \(OracleDictionary.sessionView) s
        WHERE s.SID = SYS_CONTEXT('USERENV', 'SID')
        AND p.SQL_ID = s.PREV_SQL_ID
        AND p.CHILD_NUMBER = s.PREV_CHILD_NUMBER
        ORDER BY p.ID
        """

    public static var missingGrantsMessage: String {
        String(
            localized: """
            The actual plan reads V$SESSION, V$PARAMETER and V$SQL_PLAN_STATISTICS_ALL, and this account cannot. \
            Ask for SELECT on V_$SESSION, V_$PARAMETER and V_$SQL_PLAN_STATISTICS_ALL, or for SELECT_CATALOG_ROLE. \
            The estimated plan needs no grant.
            """
        )
    }

    public static var noPlanMessage: String {
        String(localized: "Oracle returned no plan for this statement.")
    }

    // ORA-00942 is a view the account cannot see, ORA-01031 a missing privilege on one it can.
    public static func isMissingGrant(_ error: Error) -> Bool {
        guard case .queryFailed(let message) = error as? OracleCoreError else { return false }
        return message.contains("ORA-00942") || message.contains("ORA-01031")
    }

    public static func document(from result: OracleRawResult) -> String {
        let numeric = result.columns.map { isNumeric($0.typeName) }
        let objects: [[String: Any]] = result.rows.map { row in
            var object: [String: Any] = [:]
            for (index, cell) in row.enumerated() where index < result.columns.count {
                guard let text = cell.stringValue else { continue }
                object[result.columns[index].name.uppercased()] = numeric[index] ? number(text) ?? text : text
            }
            return object
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    static let planColumns = [
        "ID", "PARENT_ID", "DEPTH", "OPERATION", "OPTIONS", "OBJECT_OWNER", "OBJECT_NAME", "OBJECT_ALIAS",
        "OBJECT_TYPE", "COST", "CARDINALITY", "BYTES", "CPU_COST", "IO_COST", "TIME", "PARTITION_START",
        "PARTITION_STOP", "ACCESS_PREDICATES", "FILTER_PREDICATES", "QBLOCK_NAME"
    ]

    static let actualColumns = [
        "LAST_STARTS", "LAST_OUTPUT_ROWS", "LAST_ELAPSED_TIME", "LAST_CR_BUFFER_GETS", "LAST_DISK_READS",
        "LAST_MEMORY_USED", "LAST_TEMPSEG_SIZE"
    ]

    // EXPLAIN PLAN FOR rejects a trailing terminator.
    public static func bare(_ statement: String) -> String {
        var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func isNumeric(_ typeName: String) -> Bool {
        let upper = typeName.uppercased()
        return upper.hasPrefix("NUMBER") || upper.hasPrefix("BINARY_") || upper.hasPrefix("FLOAT")
    }

    private static func number(_ text: String) -> Any? {
        if let integer = Int(text) { return integer }
        guard let double = Double(text), double.isFinite else { return nil }
        return double
    }
}
