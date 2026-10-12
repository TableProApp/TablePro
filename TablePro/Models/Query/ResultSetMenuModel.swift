//
//  ResultSetMenuModel.swift
//  TablePro
//

import Foundation

/// One entry in the result-set chooser.
struct ResultSetMenuEntry: Equatable, Identifiable {
    let id: UUID
    let label: String
    let isPinned: Bool
    let isActive: Bool
    /// What the entry is called when the reader is counting rather than reading: "Result 2 of 4".
    let ordinal: Int
}

/// The result-set chooser, resolved before any view exists.
///
/// Replaces the 32pt strip of hand-drawn tabs. macOS has no native tab control that closes, pins or
/// reorders anything but windows: `NSTabViewItem` carries ten properties and not one of them is a
/// close affordance, `NSWindowTabGroup` takes `NSWindow` only, and SwiftUI's `Tab` and `TabSection`
/// are macOS 15 with no close either. So the collection is re-expressed rather than redrawn, and
/// the HIG names the control to re-express it with: a pop-up button is the "reasonable alternative
/// in cases where there are too many panes" for a tab view, and result sets are unbounded.
///
/// It is absent at one result, which is the common case and the strip's worst habit: a lone tab
/// spending a band of height to say "this is the result".
struct ResultSetMenuModel: Equatable {
    let entries: [ResultSetMenuEntry]
    let activeOrdinal: Int
    let total: Int

    var isEmpty: Bool { entries.isEmpty }

    /// The button's own words. A closed menu hides the count that the strip showed at a glance, so
    /// the title carries it: this is the whole mitigation for the one thing the strip did better.
    var title: String {
        guard total > 1 else { return entries.first?.label ?? "" }
        return String(
            format: String(localized: "Result %1$d of %2$d"),
            activeOrdinal,
            total
        )
    }

    /// The same count in figures, for the tiers where the bar has no room for the sentence. The
    /// chooser never leaves the bar entirely, because Pin and Close have no other one-click route.
    ///
    /// A single result is named rather than counted, and a result is named after its table or its
    /// leading comment, so the name is as long as the identifier. The chooser is `fixedSize`, so an
    /// unbounded name here sets the bar's own floor and pushes the grid out of a narrow pane.
    var compactTitle: String {
        guard total > 1 else { return Self.truncated(entries.first?.label ?? "") }
        return "\(activeOrdinal)/\(total)"
    }

    /// Long enough to tell two results apart, short enough that no name decides the bar's width.
    /// The full name stays on the menu entry and on the control's accessibility label.
    private static func truncated(_ label: String) -> String {
        let value = label as NSString
        guard value.length > compactTitleCharacterLimit else { return label }
        return value.substring(to: compactTitleCharacterLimit) + "…"
    }

    private static let compactTitleCharacterLimit = 16

    var activeEntry: ResultSetMenuEntry? {
        entries.first { $0.isActive }
    }

    /// Whether closing this entry is offered. A pinned result is pinned precisely so that nothing
    /// takes it away, which the strip enforced by withholding its close button.
    func canClose(_ entry: ResultSetMenuEntry) -> Bool {
        !entry.isPinned
    }

    func canCloseOthers(_ entry: ResultSetMenuEntry) -> Bool {
        entries.contains { $0.id != entry.id && !$0.isPinned }
    }
}
