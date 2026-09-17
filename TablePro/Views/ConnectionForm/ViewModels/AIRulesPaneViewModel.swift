//
//  AIRulesPaneViewModel.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
final class AIRulesPaneViewModel: ObservableObject {
    @Published var rules: String = ""

    @Published var coordinator: WeakCoordinatorRef?

    func load(from connection: DatabaseConnection) {
        rules = connection.aiRules ?? ""
    }

    var trimmedRules: String? {
        let trimmed = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : rules
    }
}
