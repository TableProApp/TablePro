//
//  ExplainPlanParserRegistry.swift
//  TablePro
//
//  Maps a plan format to the parser that reads it. Keyed by format rather than database type so
//  engines that share an output shape share a parser, and a plugin can name a format the app
//  does not parse yet without breaking.
//

import Foundation
import TableProPluginKit

enum ExplainPlanParserRegistry {
    static func parser(for format: ExplainPlanFormat) -> QueryPlanParser? {
        switch format {
        case .postgresJson:
            return PostgreSQLPlanParser()
        case .mysqlComposite:
            return MySQLPlanParser()
        case .sqliteQueryPlan:
            return SQLitePlanParser()
        case .cockroachText:
            return CockroachDBPlanParser()
        case .indentedText:
            return IndentedTextPlanParser()
        case .damengText:
            return DamengPlanParser()
        default:
            return nil
        }
    }

    static func plan(from rawText: String, format: ExplainPlanFormat) -> QueryPlan? {
        parser(for: format)?.parse(rawText: rawText)
    }
}
