import Foundation

public enum ExplainStep: Sendable, Hashable {
    case sqlPrefix
    // The driver's explainPlan(statement:variantId:) makes the plan; runsStatement means the statement executes.
    case driver(runsStatement: Bool)
}

public struct ExplainVariant: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let sqlPrefix: String
    public let format: ExplainPlanFormat
    public let step: ExplainStep

    public init(id: String, label: String, sqlPrefix: String, format: ExplainPlanFormat = .plainText) {
        self.init(id: id, label: label, sqlPrefix: sqlPrefix, format: format, step: .sqlPrefix)
    }

    @_disfavoredOverload
    public init(id: String, label: String, sqlPrefix: String) {
        self.init(id: id, label: label, sqlPrefix: sqlPrefix, format: .plainText)
    }

    private init(id: String, label: String, sqlPrefix: String, format: ExplainPlanFormat, step: ExplainStep) {
        self.id = id
        self.label = label
        self.sqlPrefix = sqlPrefix
        self.format = format
        self.step = step
    }

    public static func driverPlan(
        id: String,
        label: String,
        format: ExplainPlanFormat,
        runsStatement: Bool
    ) -> ExplainVariant {
        ExplainVariant(id: id, label: label, sqlPrefix: "", format: format, step: .driver(runsStatement: runsStatement))
    }
}
