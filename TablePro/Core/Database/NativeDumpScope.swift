//
//  NativeDumpScope.swift
//  TablePro
//

import Foundation

/// One object a dump can be narrowed to.
///
/// The schema is carried separately rather than folded into the name because every engine that
/// accepts a narrowed dump wants the two parts quoted apart: `pg_dump` takes `"schema"."table"`,
/// where a single pre-joined string cannot say which dot is a separator and which belongs to a name.
struct NativeDumpObject: Sendable, Hashable {
    let name: String
    let schema: String?

    init(name: String, schema: String? = nil) {
        self.name = name
        self.schema = (schema?.isEmpty ?? true) ? nil : schema
    }
}

/// How much of a database one dump covers.
enum NativeDumpScope: Sendable, Equatable {
    case wholeDatabase
    case objects([NativeDumpObject])

    var objects: [NativeDumpObject] {
        guard case .objects(let objects) = self else { return [] }
        return objects
    }

    /// An empty object list reads as the whole database rather than as nothing, so a caller that
    /// filters a selection down to zero produces a full dump instead of an empty file that looks
    /// like a successful backup.
    var isWholeDatabase: Bool {
        objects.isEmpty
    }
}

/// What narrowing a dump means on one engine, and what it costs.
///
/// Not a `Bool`. The three engines that accept a subset do three different things with it, and a
/// shared "tables to include" label would be wrong on two of them: `sqlpackage` narrows only the
/// data and always writes the whole schema, and MongoDB has collections rather than tables. The
/// engine that accepts nothing has to say so in the sheet, because silently widening a selection
/// back to the whole database is the defect this type exists to prevent.
enum NativeDumpObjectScope: Sendable, Equatable {
    /// Schema and data for the chosen tables.
    case tables(caveat: String?)
    /// The chosen collections.
    case collections
    /// The whole schema, with only the chosen tables' data.
    case dataOnly(caveat: String)
    /// The tool writes the whole database and has no filter for it.
    case unsupported(reason: String)

    var allowsNarrowing: Bool {
        guard case .unsupported = self else { return true }
        return false
    }

    /// The noun the scope tree counts in. A MongoDB row that says "42 tables" is wrong about the
    /// only thing it is there to say.
    var unitNoun: String {
        switch self {
        case .collections:
            return String(localized: "collections")
        case .tables, .dataOnly, .unsupported:
            return String(localized: "tables")
        }
    }

    var singularUnitNoun: String {
        switch self {
        case .collections:
            return String(localized: "collection")
        case .tables, .dataOnly, .unsupported:
            return String(localized: "table")
        }
    }

    /// What the sheet says once the selection is narrower than the whole database. Measured per
    /// engine rather than written once, because the consequences genuinely differ: a narrowed
    /// PostgreSQL dump does not restore at all, while a narrowed MySQL one restores and leaves a
    /// foreign key pointing at a table that is not in it.
    var narrowedCaveat: String? {
        switch self {
        case .tables(let caveat):
            return caveat
        case .collections:
            return nil
        case .dataOnly(let caveat):
            return caveat
        case .unsupported(let reason):
            return reason
        }
    }
}
