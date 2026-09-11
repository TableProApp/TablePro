//
//  FeatureTipsPlan.swift
//  TablePro
//

import Foundation

internal struct FeatureTipsPlan: Equatable, Sendable {
    internal enum Visibility: Equatable, Sendable {
        case normal
        case hideAll
        case showOnly(Set<String>)
    }

    internal static let showTipsVariable = "TABLEPRO_UI_TEST_SHOW_TIPS"

    internal let datastoreDirectory: URL
    internal let visibility: Visibility

    internal func allows(_ tipId: String) -> Bool {
        switch visibility {
        case .normal:
            return true
        case .hideAll:
            return false
        case .showOnly(let ids):
            return ids.contains(tipId)
        }
    }

    internal static func resolve(
        isUnitTestHost: Bool,
        isIsolated: Bool,
        supportDirectory: URL,
        requestedTipIds: String?
    ) -> FeatureTipsPlan? {
        guard !isUnitTestHost else { return nil }
        let directory = supportDirectory.appendingPathComponent("Tips", isDirectory: true)
        guard isIsolated else {
            return FeatureTipsPlan(datastoreDirectory: directory, visibility: .normal)
        }
        let ids = Set(
            (requestedTipIds ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        return FeatureTipsPlan(datastoreDirectory: directory, visibility: ids.isEmpty ? .hideAll : .showOnly(ids))
    }
}
