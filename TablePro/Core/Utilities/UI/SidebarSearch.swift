//
//  SidebarSearch.swift
//  TablePro
//

import Foundation

/// The sidebar filter's text, read either as a name or as a qualified path.
///
/// A plain query matches object names, and a container whose own name matches it shows everything
/// inside. A qualified one, `attendance.timesheet`, splits the two: its containers decide which
/// schemas and databases may hold a match, and only its last part is matched against object names,
/// so `attendance.` lists everything in `attendance` and nothing anywhere else. The text still
/// matches as a plain name too, or a table actually named `audit.events` could no longer be found
/// by typing its name. Matching is the same substring match the plain filter uses, never fuzzy.
internal struct SidebarSearch: Equatable, Sendable {
    internal let text: String
    internal let qualified: QualifiedSearchQuery?

    internal init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        self.text = trimmed
        self.qualified = QualifiedSearchQuery(trimmed)
    }

    internal var isEmpty: Bool {
        text.isEmpty
    }

    /// What object names are matched against. Empty for `attendance.`, where every object in an
    /// admitted container matches.
    internal var nameQuery: String {
        qualified?.name ?? text
    }

    internal func matchesName(_ name: String) -> Bool {
        SidebarNameFilter.matches(query: nameQuery, candidate: name)
    }

    /// An object matches as a path, or by holding the whole text in its own name.
    internal func matchesObject(named name: String, database: String?, schema: String?) -> Bool {
        if SidebarNameFilter.matches(query: text, candidate: name) { return true }
        guard qualified != nil else { return false }
        return admits(database: database, schema: schema) && matchesName(name)
    }

    /// Whether a container at this location may hold a match. Every container may for a plain
    /// query, which matches on object names alone.
    internal func admits(database: String?, schema: String?) -> Bool {
        guard let qualified else { return true }
        let location = QualifiedSearchQuery.location(database: database, schema: schema)
        guard let pairs = qualified.containerPairs(with: location) else { return false }
        return pairs.allSatisfy { SidebarNameFilter.matches(query: $0.query, candidate: $0.candidate) }
    }

    /// Whether the container itself answers the search: its name matches a plain query, or a
    /// qualified query admits it and asks for everything inside.
    internal func matchesContainer(database: String?, schema: String) -> Bool {
        guard let qualified else { return SidebarNameFilter.matches(query: text, candidate: schema) }
        return qualified.name.isEmpty && admits(database: database, schema: schema)
    }
}
