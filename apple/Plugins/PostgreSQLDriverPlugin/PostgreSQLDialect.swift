import Foundation
import TableProPluginKit
import TableProSQLVocabulary

enum PostgreSQLDialect {
    static let descriptor = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: SQLEngineVocabulary.postgreSQL.keywords,
        functions: SQLEngineVocabulary.postgreSQL.functions,
        dataTypes: SQLEngineVocabulary.postgreSQL.dataTypes,
        tableOptions: SQLEngineVocabulary.postgreSQL.tableOptions,
        regexSyntax: .tilde,
        booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit,
        caseSensitivityStyle: .ilikeOperator,
        operators: SQLEngineVocabulary.postgreSQL.operators.compactMap(SQLOperatorDescriptor.init(vocabulary:)),
        textCastTypeName: "TEXT",
        functionNamesAreCaseInsensitive: SQLEngineVocabulary.postgreSQL.functionNamesAreCaseInsensitive,
        typeNamesAreCaseInsensitive: true
    )
}

private extension SQLOperatorDescriptor {
    init?(vocabulary entry: SQLEngineVocabulary.Operator) {
        guard let category = Category(rawValue: entry.category),
              let placement = Placement(rawValue: entry.placement) else { return nil }
        self.init(
            symbol: entry.symbol,
            summary: entry.summary,
            category: category,
            placement: placement,
            appliesToTypes: entry.appliesToTypes
        )
    }
}
