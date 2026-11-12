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
    // Counted once here: the pull-down names every entry, and counting per entry made a 10,000-statement run quadratic.
    private let positions: [UUID: Int]
    private let occurrences: [Int?]

    init(entries: [ResultSetMenuEntry], activeOrdinal: Int, total: Int) {
        self.entries = entries
        self.activeOrdinal = activeOrdinal
        self.total = total
        positions = Dictionary(entries.enumerated().map { ($1.id, $0) }) { first, _ in first }
        occurrences = Self.occurrenceNumbers(in: entries.map(\.label))
    }

    static func == (lhs: ResultSetMenuModel, rhs: ResultSetMenuModel) -> Bool {
        lhs.entries == rhs.entries && lhs.activeOrdinal == rhs.activeOrdinal && lhs.total == rhs.total
    }

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
        guard let index = positions[entry.id] else { return entry.label }
        return Self.counted(entries[index].label, occurrence: occurrences[index])
    }

    // The name is cut before the occurrence is added, so "(2)" always survives.
    func tabTitle(of entry: ResultSetMenuEntry) -> String {
        guard let index = positions[entry.id] else { return entry.label }
        return Self.counted(Self.truncated(entry.label, limit: Self.tabTitleCharacterLimit), occurrence: occurrences[index])
    }

    // Two results read from one table share a name; the later ones carry their occurrence so two never look alike.
    static func displayLabel(at index: Int, in labels: [String]) -> String {
        let earlier = labels[..<index].filter { $0 == labels[index] }.count
        return counted(labels[index], occurrence: earlier > 0 ? earlier + 1 : nil)
    }

    // Every name at once, for a caller naming each result of a tab.
    static func displayLabels(for labels: [String]) -> [String] {
        zip(labels, occurrenceNumbers(in: labels)).map { counted($0, occurrence: $1) }
    }

    private static func occurrenceNumbers(in labels: [String]) -> [Int?] {
        var seen: [String: Int] = [:]
        return labels.map { label in
            let earlier = seen[label, default: 0]
            seen[label] = earlier + 1
            return earlier > 0 ? earlier + 1 : nil
        }
    }

    private static func counted(_ name: String, occurrence: Int?) -> String {
        guard let occurrence else { return name }
        return String(format: String(localized: "%1$@ (%2$d)"), name, occurrence)
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
