import Foundation

public struct PluginSQLCaseFolding: Sendable {
    public let likeKeyword: String
    public let notLikeKeyword: String
    public let foldsLikeOperands: Bool
    public let foldsComparisonOperands: Bool
    public let usesRegexForLike: Bool
    public let foldFunction: String

    public static func resolve(
        style: SQLDialectDescriptor.CaseSensitivityStyle,
        foldFunction: String = SQLDialectDescriptor.defaultCaseFoldFunction,
        isCaseSensitive: Bool
    ) -> PluginSQLCaseFolding {
        guard !isCaseSensitive else { return caseSensitive(foldFunction: foldFunction) }
        switch style {
        case .ilikeOperator:
            return PluginSQLCaseFolding(
                likeKeyword: "ILIKE",
                notLikeKeyword: "NOT ILIKE",
                foldsLikeOperands: false,
                foldsComparisonOperands: true,
                usesRegexForLike: false,
                foldFunction: foldFunction
            )
        case .caseFoldFunction:
            return PluginSQLCaseFolding(
                likeKeyword: "LIKE",
                notLikeKeyword: "NOT LIKE",
                foldsLikeOperands: true,
                foldsComparisonOperands: true,
                usesRegexForLike: false,
                foldFunction: foldFunction
            )
        case .regexFlag:
            return PluginSQLCaseFolding(
                likeKeyword: "LIKE",
                notLikeKeyword: "NOT LIKE",
                foldsLikeOperands: false,
                foldsComparisonOperands: false,
                usesRegexForLike: true,
                foldFunction: foldFunction
            )
        case .driverManaged, .collationDefined, .unsupported:
            return caseSensitive(foldFunction: foldFunction)
        }
    }

    public static func isAdjustable(style: SQLDialectDescriptor.CaseSensitivityStyle) -> Bool {
        switch style {
        case .ilikeOperator, .caseFoldFunction, .regexFlag, .driverManaged:
            return true
        case .collationDefined, .unsupported:
            return false
        }
    }

    public func fold(_ expression: String) -> String {
        "\(foldFunction)(\(expression))"
    }

    public func foldingComparison(_ expression: String) -> String {
        foldsComparisonOperands ? fold(expression) : expression
    }

    public func foldingLikeOperand(_ expression: String) -> String {
        foldsLikeOperands ? fold(expression) : expression
    }

    private static func caseSensitive(foldFunction: String) -> PluginSQLCaseFolding {
        PluginSQLCaseFolding(
            likeKeyword: "LIKE",
            notLikeKeyword: "NOT LIKE",
            foldsLikeOperands: false,
            foldsComparisonOperands: false,
            usesRegexForLike: false,
            foldFunction: foldFunction
        )
    }
}
