import Foundation

/// The shape of the text a database returns for an EXPLAIN variant. String-based rather than an
/// enum so a plugin can name a format the app does not know yet without a PluginKit release.
public struct ExplainPlanFormat: Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public extension ExplainPlanFormat {
    /// Output the app has no structured parser for. Rendered as text.
    static let plainText = ExplainPlanFormat(rawValue: "plainText")

    static let postgresJson = ExplainPlanFormat(rawValue: "postgresJson")
    static let mysqlComposite = ExplainPlanFormat(rawValue: "mysqlComposite")
    static let sqliteQueryPlan = ExplainPlanFormat(rawValue: "sqliteQueryPlan")
    static let cockroachText = ExplainPlanFormat(rawValue: "cockroachText")
    static let indentedText = ExplainPlanFormat(rawValue: "indentedText")
    static let damengText = ExplainPlanFormat(rawValue: "damengText")

    // JSON array of PLAN_TABLE or V$SQL_PLAN_STATISTICS_ALL rows keyed by column name, NULL columns left out.
    static let oraclePlanRows = ExplainPlanFormat(rawValue: "oraclePlanRows")

    static let sqlServerShowplanXML = ExplainPlanFormat(rawValue: "sqlServerShowplanXML")
}
