//
//  ClickHouseExplainVariant.swift
//  TablePro
//
//  EXPLAIN variants supported by ClickHouse.
//

import Foundation

/// ClickHouse-specific EXPLAIN variants
enum ClickHouseExplainVariant: String, CaseIterable, Identifiable {
    case plan = "Plan"
    case pipeline = "Pipeline"
    case ast = "AST"
    case syntax = "Syntax"
    case estimate = "Estimate"

    var id: String { rawValue }

    /// SQL keyword to prepend to the query
    var sqlKeyword: String {
        switch self {
        case .plan: return "EXPLAIN"
        case .pipeline: return "EXPLAIN PIPELINE"
        case .ast: return "EXPLAIN AST"
        case .syntax: return "EXPLAIN SYNTAX"
        case .estimate: return "EXPLAIN ESTIMATE"
        }
    }
}
