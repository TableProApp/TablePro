//
//  ClickHouseCapabilities.swift
//  ClickHouseDriverPlugin
//

import Foundation

struct ClickHouseCapabilities: Sendable, Equatable {
    let major: Int
    let minor: Int

    static let unknown = ClickHouseCapabilities(major: 0, minor: 0)

    var hasDataSkippingIndicesTable: Bool {
        major > 19 || (major == 19 && minor >= 17)
    }

    static func parse(_ version: String?) -> ClickHouseCapabilities {
        guard let version else { return .unknown }
        let parts = version.split(separator: ".")
        guard let major = parts.first.flatMap({ Int($0) }) else { return .unknown }
        let minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return ClickHouseCapabilities(major: major, minor: minor)
    }
}
