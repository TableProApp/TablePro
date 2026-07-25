//
//  ScannedProductionHeuristic.swift
//  TablePro
//

import Foundation

enum ScannedProductionHeuristic {
    private static let markers: Set<String> = ["prod", "production", "live"]

    static func isProduction(relativePath: String, host: String, database: String) -> Bool {
        [relativePath, host, database].contains(where: containsMarker)
    }

    private static func containsMarker(_ value: String) -> Bool {
        let tokens = value.lowercased().split { !$0.isLetter && !$0.isNumber }
        return tokens.contains { markers.contains(String($0)) }
    }
}
