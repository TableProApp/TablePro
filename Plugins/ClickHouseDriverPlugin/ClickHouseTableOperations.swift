//
//  ClickHouseTableOperations.swift
//  ClickHouseDriverPlugin
//

import Foundation

func clickHouseTableType(forEngine engine: String?) -> String {
    switch engine {
    case "MaterializedView":
        return "MATERIALIZED VIEW"
    case "View", "LiveView", "WindowView":
        return "VIEW"
    default:
        return "TABLE"
    }
}

func clickHouseDropObjectStatement(name: String, objectType: String) -> String? {
    guard objectType == "MATERIALIZED VIEW" else { return nil }
    let escaped = name.replacingOccurrences(of: "`", with: "``")
    return "DROP VIEW `\(escaped)`"
}
