//
//  DatabaseConnection+Masking.swift
//  TablePro
//

import Foundation
import os

extension DatabaseConnection {
    // Kept in the additional fields, which iCloud sync and a published Team Catalog entry already carry.
    static let maskingRulesKey = "maskingRules"

    private static let maskingLogger = Logger(subsystem: "com.TablePro", category: "Masking")

    var maskingRules: [MaskingRule] {
        get {
            guard let json = additionalFields[Self.maskingRulesKey], !json.isEmpty else { return [] }
            do {
                return try JSONDecoder().decode([MaskingRule].self, from: Data(json.utf8))
            } catch {
                Self.maskingLogger.error("Masking rules could not be read: \(error.publicLogShape, privacy: .public)")
                return [.maskEverything]
            }
        }
        set {
            let kept = newValue.filter { !$0.trimmedPattern.isEmpty }
            guard !kept.isEmpty,
                  let data = try? JSONEncoder().encode(kept),
                  let json = String(data: data, encoding: .utf8) else {
                additionalFields.removeValue(forKey: Self.maskingRulesKey)
                return
            }
            additionalFields[Self.maskingRulesKey] = json
        }
    }

    var maskingPolicy: MaskingPolicy {
        MaskingPolicy(rules: maskingRules)
    }
}
