//
//  MaskingRulesPaneViewModel.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
final class MaskingRulesPaneViewModel: ObservableObject {
    @Published var rules: [MaskingRule] = []

    @Published var coordinator: WeakCoordinatorRef?

    func load(from connection: DatabaseConnection) {
        rules = connection.maskingRules
    }

    func addRule() {
        rules.append(MaskingRule(pattern: ""))
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    func update(_ rule: MaskingRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
    }

    var savedRules: [MaskingRule] {
        rules.filter { !$0.trimmedPattern.isEmpty }
    }
}
