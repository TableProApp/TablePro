//
//  SymbolPickerModel.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

internal enum SymbolPickerItem: Hashable {
    case defaultIcon
    case symbol(String)

    internal var iconName: String? {
        switch self {
        case .defaultIcon: return nil
        case .symbol(let name): return name
        }
    }
}

internal struct SymbolPickerModel {
    internal static let columnCount = 8
    internal static let defaultTitle = String(localized: "Default")

    /// A stored name the catalog does not list (synced from a newer release) selects no cell.
    internal let selection: String?
    internal var query = "" {
        didSet { refresh() }
    }
    internal private(set) var sections: [LibrarySymbolSection]
    internal private(set) var showsDefault = true
    internal var highlight: SymbolPickerItem?

    internal init(selection: String?) {
        let normalized = LibrarySymbolCatalog.normalizedName(selection)
        self.selection = normalized
        self.sections = LibrarySymbolCatalog.sections
        self.highlight = Self.item(for: normalized)
    }

    internal var items: [SymbolPickerItem] {
        let symbols = sections.flatMap { section in section.symbols.map { SymbolPickerItem.symbol($0.name) } }
        return showsDefault ? [.defaultIcon] + symbols : symbols
    }

    /// The grid as it is drawn: Default alone on the first row, then each category in rows of
    /// `columnCount`, so a category's last row is often short.
    internal var rows: [[SymbolPickerItem]] {
        var rows: [[SymbolPickerItem]] = showsDefault ? [[.defaultIcon]] : []
        for section in sections {
            let items = section.symbols.map { SymbolPickerItem.symbol($0.name) }
            for start in stride(from: 0, to: items.count, by: Self.columnCount) {
                rows.append(Array(items[start ..< min(start + Self.columnCount, items.count)]))
            }
        }
        return rows
    }

    internal var isEmpty: Bool {
        !showsDefault && sections.isEmpty
    }

    internal func isSelected(_ item: SymbolPickerItem) -> Bool {
        item.iconName == selection
    }

    /// Up and Down keep the column, landing on the last cell of a shorter row, and stop at either end.
    internal mutating func moveUp() {
        moveHighlight(rows: -1)
    }

    internal mutating func moveDown() {
        moveHighlight(rows: 1)
    }

    internal func commit() -> SymbolPickerItem? {
        guard let highlight, items.contains(highlight) else { return nil }
        return highlight
    }

    private mutating func moveHighlight(rows delta: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        guard let current = highlight,
              let row = rows.firstIndex(where: { $0.contains(current) }),
              let column = rows[row].firstIndex(of: current)
        else {
            highlight = delta > 0 ? rows.first?.first : rows.last?.last
            return
        }
        let target = rows[min(max(row + delta, 0), rows.count - 1)]
        highlight = target[min(column, target.count - 1)]
    }

    private mutating func refresh() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        sections = LibrarySymbolCatalog.sections(matching: term)
        showsDefault = term.isEmpty || Self.defaultTitle.localizedStandardContains(term)
        if let highlight, items.contains(highlight) { return }
        highlight = bestMatch(for: term)
    }

    /// Never the first cell on its own: a query that matched only by substring arms nothing, so
    /// Return cannot pick an icon the user never looked at.
    private func bestMatch(for term: String) -> SymbolPickerItem? {
        guard !term.isEmpty else { return Self.item(for: selection) }
        let match = LibrarySymbolCatalog.bestMatch(for: term, in: sections.flatMap(\.symbols))
        guard showsDefault, Self.hasPrefix(Self.defaultTitle, term) else {
            return match.map { .symbol($0.name) }
        }
        if let match, !Self.isEqual(Self.defaultTitle, term),
           Self.isEqual(match.title, term) || Self.isEqual(match.name, term) {
            return .symbol(match.name)
        }
        return .defaultIcon
    }

    private static func item(for selection: String?) -> SymbolPickerItem? {
        guard let selection else { return .defaultIcon }
        return LibrarySymbolCatalog.symbol(named: selection).map { .symbol($0.name) }
    }

    private static func isEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        text.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
    }
}
