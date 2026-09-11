//
//  MySQLConnectionEncoding.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum MySQLConnectionEncoding: String, CaseIterable, Sendable {
    case utf8 = ""
    case utf8ViaLatin1

    static let fieldId = "mysqlConnectionEncoding"
    static let sessionCharacterSetName = "utf8mb4"
    static let sessionFallbackStatement = "SET NAMES utf8"

    static var connectionField: ConnectionField {
        ConnectionField(
            id: fieldId,
            label: String(localized: "Encoding"),
            fieldType: .dropdown(options: allCases.map { .init(value: $0.rawValue, label: $0.displayName) }),
            section: .advanced
        )
    }

    init(fieldValue: String?) {
        self = fieldValue.flatMap(Self.init(rawValue:)) ?? .utf8
    }

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8ViaLatin1: return String(localized: "UTF-8 via Latin 1")
        }
    }

    var sessionStatements: [String] {
        switch self {
        case .utf8: return []
        case .utf8ViaLatin1: return ["SET character_set_client = latin1"]
        }
    }

    func presentedText(_ text: String) -> String {
        switch self {
        case .utf8: return text
        case .utf8ViaLatin1: return MySQLLatin1.repairingDoubleEncodedUTF8(text)
        }
    }
}
