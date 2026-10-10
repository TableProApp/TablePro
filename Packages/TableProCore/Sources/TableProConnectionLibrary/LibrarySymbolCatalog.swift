import Foundation

public enum LibrarySymbolCategory: String, CaseIterable, Sendable {
    case databaseAndStorage
    case serversAndNetwork
    case environmentsAndStatus
    case securityAndAccess
    case dataAndAnalytics
    case development
    case workAndPlaces
    case symbolsAndObjects

    public var title: String {
        switch self {
        case .databaseAndStorage: String(localized: "Database & Storage")
        case .serversAndNetwork: String(localized: "Servers & Network")
        case .environmentsAndStatus: String(localized: "Environments & Status")
        case .securityAndAccess: String(localized: "Security & Access")
        case .dataAndAnalytics: String(localized: "Data & Analytics")
        case .development: String(localized: "Development")
        case .workAndPlaces: String(localized: "Work & Places")
        case .symbolsAndObjects: String(localized: "Symbols & Objects")
        }
    }
}

public struct LibrarySymbol: Hashable, Identifiable, Sendable {
    public let name: String
    public let category: LibrarySymbolCategory
    public let title: String
    public let keywords: [String]

    public var id: String { name }

    init(_ name: String, _ category: LibrarySymbolCategory, _ title: String, _ keywords: [String]) {
        self.name = name
        self.category = category
        self.title = title
        self.keywords = keywords
    }
}

public struct LibrarySymbolSection: Hashable, Identifiable, Sendable {
    public let category: LibrarySymbolCategory
    public let symbols: [LibrarySymbol]

    public var id: LibrarySymbolCategory { category }
}

/// The SF Symbols a connection or a group can wear instead of its default glyph.
///
/// Every name is the spelling macOS 13 and iOS 16 know. Several were renamed in later SF Symbols
/// releases (`doc.text`, `terminal`, `gauge`), and the old name still resolves on every newer OS,
/// while the new one is nil on a Mac or iPhone that syncs the same record from an older release.
public enum LibrarySymbolCatalog {
    public static let maximumNameLength = 100

    public static var symbols: [LibrarySymbol] { entries }

    public static var sections: [LibrarySymbolSection] { sections(of: entries) }

    public static func symbol(named name: String) -> LibrarySymbol? {
        entries.first { $0.name == name }
    }

    /// A stored or imported icon name in the shape of an SF Symbol name, or nil.
    ///
    /// This is the boundary check for anything read from a file, a link, a teammate's folder or
    /// CloudKit. It does not require the name to be in the catalog, because a newer release may
    /// offer symbols this one does not list; whether the name draws is a platform question the
    /// caller answers with `NSImage(systemSymbolName:)` or `UIImage(systemName:)`.
    public static func normalizedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= maximumNameLength else { return nil }
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        let isWellFormed = components.allSatisfy { component in
            !component.isEmpty && component.unicodeScalars.allSatisfy(isNameScalar)
        }
        return isWellFormed ? name : nil
    }

    /// The catalog filtered by `query`, in catalog order and grouped by category, so a search
    /// keeps the headers a person scans by. An empty query returns every section.
    public static func sections(matching query: String) -> [LibrarySymbolSection] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return sections }
        return sections(of: entries.filter { matches($0, term: term) })
    }

    /// The symbol a Return should pick for `query`: an exact title or name, then a title prefix,
    /// then a keyword prefix. Nil when nothing in `symbols` is a strong enough match, so a query
    /// that matched only by substring never picks the first cell on its own.
    public static func bestMatch(for query: String, in symbols: [LibrarySymbol]) -> LibrarySymbol? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        if let exact = symbols.first(where: { isEqual($0.title, term) || isEqual($0.name, term) }) {
            return exact
        }
        if let prefix = symbols.first(where: { hasPrefix($0.title, term) }) {
            return prefix
        }
        return symbols.first { symbol in symbol.keywords.contains { hasPrefix($0, term) } }
    }

    private static func sections(of symbols: [LibrarySymbol]) -> [LibrarySymbolSection] {
        LibrarySymbolCategory.allCases.compactMap { category in
            let members = symbols.filter { $0.category == category }
            return members.isEmpty ? nil : LibrarySymbolSection(category: category, symbols: members)
        }
    }

    private static func matches(_ symbol: LibrarySymbol, term: String) -> Bool {
        if symbol.title.localizedStandardContains(term) { return true }
        if symbol.keywords.contains(where: { $0.localizedStandardContains(term) }) { return true }
        return symbol.name.split(separator: ".").contains { String($0).localizedStandardContains(term) }
    }

    private static func isEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        text.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar)
    }
}
