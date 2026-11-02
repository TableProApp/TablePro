//
//  ProjectScanExpansionBudget.swift
//  TablePro
//

import Foundation

// What dotenv references, compose substitutions and YAML aliases may add to a folder scan beyond the bytes of its
// files. Each of them can turn a few hundred bytes into gigabytes, so one scan shares one allowance.
final class ProjectScanExpansionBudget {
    static let standardLimit = 1 << 20

    private(set) var remaining: Int

    init(limit: Int = standardLimit) {
        remaining = max(limit, 0)
    }

    func spend(_ amount: Int) -> Bool {
        guard amount <= remaining else { return false }
        remaining -= max(amount, 0)
        return true
    }
}
