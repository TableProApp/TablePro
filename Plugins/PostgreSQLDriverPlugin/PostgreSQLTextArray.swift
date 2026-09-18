//
//  PostgreSQLTextArray.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

enum PostgreSQLTextArray {
    static func elements(_ text: String?) -> [String?] {
        guard let text, let parsed = PostgresArrayLiteralCodec.parse(text) else { return [] }
        return parsed.map { element in
            guard case .value(let value) = element else { return nil }
            return value
        }
    }

    static func values(_ text: String?) -> [String] {
        elements(text).compactMap { $0 }
    }
}
