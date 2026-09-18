//
//  StoredBoolean.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum StoredBoolean {
    static func value(of text: String) -> Bool? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch PluginSQLLiteral.booleanSynonym(for: trimmed) {
        case .isTrue:
            return true
        case .isFalse:
            return false
        default:
            break
        }
        switch trimmed.lowercased() {
        case "t":
            return true
        case "f":
            return false
        default:
            return nil
        }
    }
}
