import Foundation

/// The sidebar filter's text, read either as a name or as a qualified path.
///
/// A plain query matches object names, and a container whose own name matches it shows everything
/// inside. A qualified one, `attendance.timesheet`, splits the two: its containers decide which
/// schemas and databases may hold a match, and only its last part is matched against object names,
/// so `attendance.` lists everything in `attendance` and nothing anywhere else. The text still
/// matches as a plain name too, or a table actually named `audit.events` could no longer be found
/// by typing its name. Matching is the same substring match the plain filter uses, never fuzzy.
public struct SidebarSearch: Equatable, Sendable {
    public let text: String
    public let qualified: QualifiedSearchQuery?
    private let textQuery: SidebarNameQuery
    private let nameMatcher: SidebarNameQuery

    public init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let qualified = QualifiedSearchQuery(trimmed)
        self.text = trimmed
        self.qualified = qualified
        self.textQuery = SidebarNameQuery(trimmed)
        self.nameMatcher = SidebarNameQuery(qualified?.name ?? trimmed)
    }

    public var isEmpty: Bool {
        text.isEmpty
    }

    /// What object names are matched against. Empty for `attendance.`, where every object in an
    /// admitted container matches.
    public var nameQuery: String {
        qualified?.name ?? text
    }

    public func matchesName(_ name: String) -> Bool {
        nameMatcher.tier(of: name) != nil
    }

    // An object matches as a path, or by holding the whole text in its own name.
    public func matchesObject(named name: String, database: String?, schema: String?) -> Bool {
        if textQuery.tier(of: name) != nil { return true }
        guard qualified != nil else { return false }
        return admits(database: database, schema: schema) && matchesName(name)
    }

    // What `matchesObject` then `SidebarNameFilter.ranked` by `nameQuery` decide, in one look at the name.
    public func rankTier(named name: String, database: String?, schema: String?) -> SidebarNameMatchTier? {
        guard qualified != nil else { return textQuery.tier(of: name) }
        guard let tier = nameMatcher.tier(of: name) else { return nil }
        if admits(database: database, schema: schema) || textQuery.tier(of: name) != nil { return tier }
        return nil
    }

    // The matching objects, exact names first, then prefixes, then the rest, each in arrival order.
    public func ranked<Element>(
        _ items: [Element],
        name: (Element) -> String,
        database: String?,
        schema: (Element) -> String?
    ) -> [Element] {
        guard !isEmpty else { return items }
        var matches = SidebarRankedMatches<Element>()
        for item in items {
            guard let tier = rankTier(named: name(item), database: database, schema: schema(item)) else { continue }
            matches.append(item, tier: tier)
        }
        return matches.elements
    }

    /// Whether a container at this location may hold a match. Every container may for a plain
    /// query, which matches on object names alone.
    public func admits(database: String?, schema: String?) -> Bool {
        guard let qualified else { return true }
        let location = QualifiedSearchQuery.location(database: database, schema: schema)
        guard let pairs = qualified.containerPairs(with: location) else { return false }
        return pairs.allSatisfy { SidebarNameFilter.matches(query: $0.query, candidate: $0.candidate) }
    }

    /// Whether the container itself answers the search: its name matches a plain query, or a
    /// qualified query admits it and asks for everything inside.
    public func matchesContainer(database: String?, schema: String) -> Bool {
        guard let qualified else { return SidebarNameFilter.matches(query: text, candidate: schema) }
        return qualified.name.isEmpty && admits(database: database, schema: schema)
    }
}
