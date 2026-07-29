//
//  RDSEndpoint.swift
//  TablePro
//

import Foundation

enum RDSEndpoint {
    static func region(forHost host: String) -> String? {
        let parts = host.split(separator: ".").map(String.init)
        guard let rdsIndex = parts.firstIndex(of: "rds"),
              rdsIndex > 0,
              parts.count > rdsIndex + 1,
              parts[rdsIndex + 1] == "amazonaws" else {
            return nil
        }
        let region = parts[rdsIndex - 1]
        return region.isEmpty ? nil : region
    }
}
