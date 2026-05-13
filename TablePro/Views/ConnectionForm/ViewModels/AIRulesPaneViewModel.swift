//
//  AIRulesPaneViewModel.swift
//  TablePro
//

import Foundation

@Observable
@MainActor
final class AIRulesPaneViewModel {
    var rules: String = ""

    var coordinator: WeakCoordinatorRef?

    func load(from connection: DatabaseConnection) {
        rules = connection.aiRules ?? ""
    }

    var trimmedRules: String? {
        let trimmed = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : rules
    }
}
