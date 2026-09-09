//
//  ForeignKeyReferenceVocabulary.swift
//  TablePro
//

import Foundation

/// The lists the Foreign Keys grid offers for a referencing column, a referenced table and a
/// referenced column.
///
/// Every list ends in `Custom…`, the `GridMenuOption` shape `ColumnDefaultVocabulary` established
/// for an open vocabulary: the menu writes a name that exists, and typing still writes anything.
/// That matters here because a table the sidebar has not loaded, or one about to be created in the
/// same session, must stay reachable.
@MainActor
enum ForeignKeyReferenceVocabulary {
    static func options(names: [String], loading: Bool) -> [GridMenuOption] {
        var options: [GridMenuOption] = []
        if loading {
            options.append(.sectionHeader(String(localized: "Loading…")))
        }
        options.append(contentsOf: GridMenuOption.values(sorted(names)))
        options.append(.custom(title: String(localized: "Custom…")))
        return options
    }

    /// A comma-separated cell holds a list, so the menu appends rather than replaces. Picking three
    /// columns for a composite key means opening the menu three times, which is how the referenced
    /// side has to be built anyway.
    static func appending(_ name: String, to current: String?) -> String {
        let existing = (current ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !existing.contains(name) else { return existing.joined(separator: ", ") }
        return (existing + [name]).joined(separator: ", ")
    }

    private static func sorted(_ names: [String]) -> [String] {
        Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
