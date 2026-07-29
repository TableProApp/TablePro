//
//  SnowflakeBindingEncoder.swift
//  SnowflakeDriverPlugin
//
//  Encodes PluginCellValue parameters into the Snowflake v1 query-request
//  "bindings" payload: 1-based string keys, TEXT for scalar values (the server
//  coerces into the target column type), BINARY as hex, null as a typed null.
//

import Foundation
import TableProPluginKit

enum SnowflakeBindingEncoder {
    static func encode(_ parameters: [PluginCellValue]) -> [String: [String: Any]] {
        var bindings: [String: [String: Any]] = [:]
        bindings.reserveCapacity(parameters.count)
        for (index, parameter) in parameters.enumerated() {
            bindings[String(index + 1)] = binding(for: parameter)
        }
        return bindings
    }

    private static func binding(for value: PluginCellValue) -> [String: Any] {
        switch value {
        case .null:
            return ["type": "TEXT", "value": NSNull()]
        case .text(let text):
            return ["type": "TEXT", "value": text]
        case .bytes(let data):
            return ["type": "BINARY", "value": hex(data)]
        default:
            return ["type": "TEXT", "value": NSNull()]
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
