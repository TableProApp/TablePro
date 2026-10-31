//
//  ResultSetMenuModel.swift
//  TablePro
//

import Foundation

struct ResultSetMenuEntry: Equatable, Identifiable {
    let id: UUID
    let label: String
    let isPinned: Bool
    let isActive: Bool
    // What the entry is called when the reader is counting rather than reading: "Result 2 of 4".
    let ordinal: Int
    // Whether it holds columns to compare: a plan, an error or a statement that returned no rows does not.
    let isComparable: Bool
}

// Backs both the tab row and the pull-down, so the two never disagree on names or on what can close.
struct ResultSetMenuModel: Equatable {
    let entries: [ResultSetMenuEntry]
    let activeOrdinal: Int
    let total: Int

    // HIG, Tab views: "Avoid providing more than six tabs". Past that the pull-down alone lists them.
    static let maximumTabCount = 6

    var isEmpty: Bool { entries.isEmpty }

    var offersTabs: Bool {
        (2 ... Self.maximumTabCount).contains(total)
    }

    // A position, not a name: a counted name such as "Result 3" keeps its number after an earlier result closes.
    var title: String {
        guard total > 1 else { return entries.first.map(displayLabel(of:)) ?? "" }
        return String(format: String(localized: "%1$d of %2$d"), activeOrdinal, total)
    }

    // The chooser is `fixedSize`, so an unbounded name here would set the bar's floor and push the grid out of a narrow pane.
    var compactTitle: String {
        guard total > 1 else { return Self.truncated(title, limit: Self.compactTitleCharacterLimit) }
        return "\(activeOrdinal)/\(total)"
    }

    var activeEntry: ResultSetMenuEntry? {
        entries.first { $0.isActive }
    }

    func displayLabel(of entry: ResultSetMenuEntry) -> String {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return entry.label }
        return Self.displayLabel(at: index, in: entries.map(\.label))
    }

    // The name is cut before the occurrence is added, so "(2)" always survives.
    func tabTitle(of entry: ResultSetMenuEntry) -> String {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return entry.label }
        let labels = entries.map(\.label)
        let name = Self.truncated(entry.label, limit: Self.tabTitleCharacterLimit)
        guard let occurrence = Self.occurrence(at: index, in: labels) else { return name }
        return String(format: String(localized: "%1$@ (%2$d)"), name, occurrence)
    }

    // Two results read from one table share a name; the later ones carry their occurrence so two never look alike.
    static func displayLabel(at index: Int, in labels: [String]) -> String {
        guard let occurrence = occurrence(at: index, in: labels) else { return labels[index] }
        return String(format: String(localized: "%1$@ (%2$d)"), labels[index], occurrence)
    }

    private static func occurrence(at index: Int, in labels: [String]) -> Int? {
        let earlier = labels[..<index].filter { $0 == labels[index] }.count
        return earlier > 0 ? earlier + 1 : nil
    }

    // A pinned result is pinned precisely so that nothing takes it away.
    func canClose(_ entry: ResultSetMenuEntry) -> Bool {
        !entry.isPinned
    }

    func canCloseOthers(_ entry: ResultSetMenuEntry) -> Bool {
        entries.contains { $0.id != entry.id && !$0.isPinned }
    }

    func canCompare(_ entry: ResultSetMenuEntry) -> Bool {
        entry.isComparable
    }

    // Counts Characters, so an emoji or a combining mark is never cut into a replacement character.
    static func truncated(_ label: String, limit: Int) -> String {
        guard label.count > limit else { return label }
        return String(label.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let compactTitleCharacterLimit = 16
    private static let tabTitleCharacterLimit = 24
}
