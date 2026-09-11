//
//  HighlightColumnOption.swift
//  TablePro
//

import Foundation

struct HighlightColumnOption: Identifiable, Hashable {
    let name: String
    let occurrence: Int
    let label: String

    var id: String { Self.identifier(name: name, occurrence: occurrence) }

    static func identifier(name: String, occurrence: Int) -> String {
        "\(occurrence)#\(name)"
    }

    static func options(for columns: [String]) -> [HighlightColumnOption] {
        var seen: [String: Int] = [:]
        let totals = columns.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return columns.map { name in
            let occurrence = seen[name, default: 0]
            seen[name] = occurrence + 1
            let label = totals[name, default: 0] > 1
                ? String(format: String(localized: "%1$@ (%2$d)"), name, occurrence + 1)
                : name
            return HighlightColumnOption(name: name, occurrence: occurrence, label: label)
        }
    }
}
