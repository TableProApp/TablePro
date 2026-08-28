//
//  ObjectCopyRequest.swift
//  TablePro
//
//  What the user asked to copy, where to, and how.
//
//  A copy is not a comparison run against an empty target. Comparing would
//  materialise one INSERT statement per row before anything ran, which is the
//  cost this feature exists to avoid, so the request carries the objects
//  directly and the runner streams their rows.
//

import Foundation
import TableProPluginKit

/// Which halves of an object take part.
internal enum ObjectCopyContent: String, CaseIterable, Hashable, Sendable {
    case structure
    case data
    case structureAndData

    internal var includesStructure: Bool { self != .data }
    internal var includesData: Bool { self != .structure }

    internal var displayName: String {
        switch self {
        case .structure: return String(localized: "Structure only")
        case .data: return String(localized: "Data only")
        case .structureAndData: return String(localized: "Structure and data")
        }
    }
}

/// What to do about an object the target already has.
///
/// There is no silent default here. Overwriting is a drop, and appending into a table whose rows
/// are already there duplicates them, so the choice is made before the run rather than guessed.
internal enum ObjectCopyExistingPolicy: String, CaseIterable, Hashable, Sendable {
    case skip
    case replace
    case appendData

    internal var displayName: String {
        switch self {
        case .skip: return String(localized: "Skip it")
        case .replace: return String(localized: "Replace it")
        case .appendData: return String(localized: "Add rows to it")
        }
    }

    /// Only `replace` drops what the target already has.
    internal var dropsTargetObject: Bool { self == .replace }
}

/// Where the copy is written.
internal enum ObjectCopyDestination: Hashable, Sendable {
    /// A database that is already there. The endpoint names it, including its schema where the
    /// engine has schemas.
    case existing(DatabaseEndpoint)
    /// A database this run creates first, on the connection `base` reaches. `values` are the
    /// answers to the driver's own `createDatabaseFormSpec`, so charset and collation are the
    /// user's rather than the server's default.
    case newDatabase(base: DatabaseEndpoint, name: String, values: [String: String])

    /// The database the objects land in, which for a new database is the one about to be created.
    internal var endpoint: DatabaseEndpoint {
        switch self {
        case .existing(let endpoint): return endpoint
        case .newDatabase(let base, let name, _): return base.withDatabase(name)
        }
    }

    internal var createsDatabase: Bool {
        guard case .newDatabase = self else { return false }
        return true
    }
}

/// One object the user chose to copy.
///
/// A name is not an identity. PostgreSQL and Oracle both allow `f(integer)` and `f(text)` at once,
/// and every engine with triggers allows the same trigger name on two tables. Keying on the name
/// alone gave those objects one `Hashable` value and one `id`, so the picker collapsed them into
/// one row and the planner's dictionaries kept whichever arrived last.
internal struct ObjectCopySelection: Hashable, Identifiable, Sendable {
    internal let kind: CompareObjectKind
    internal let name: String
    internal let schema: String?
    /// A routine's argument list, which is what tells two overloads apart. Nil for every kind that
    /// cannot be overloaded.
    internal let signature: String?
    /// The table a trigger hangs off. Nil for everything else.
    internal let owner: String?

    internal init(
        kind: CompareObjectKind,
        name: String,
        schema: String?,
        signature: String? = nil,
        owner: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.schema = schema
        self.signature = signature
        self.owner = owner
    }

    internal var id: String {
        [kind.rawValue, schema ?? "", name, signature ?? "", owner ?? ""]
            .map { $0.replacingOccurrences(of: "\u{1F}", with: "\u{1F}\u{1F}") }
            .joined(separator: "\u{1F}")
    }

    internal var qualifiedName: String {
        guard let schema, !schema.isEmpty else { return name }
        return "\(schema).\(name)"
    }

    /// What the object list shows. A bare name is ambiguous exactly where the identity needed the
    /// extra part, so the row carries it too.
    internal var displayName: String {
        if let signature, !signature.isEmpty { return "\(name)\(signature)" }
        if let owner, !owner.isEmpty {
            return String(format: String(localized: "%1$@ on %2$@"), name, owner)
        }
        return name
    }
}

internal struct ObjectCopyRequest: Sendable {
    internal let source: DatabaseEndpoint
    internal let destination: ObjectCopyDestination
    internal let objects: [ObjectCopySelection]
    internal let content: ObjectCopyContent
    internal let existingPolicy: ObjectCopyExistingPolicy
    internal let errorHandling: ImportErrorHandling
    internal let wrapEachTableInTransaction: Bool

    internal init(
        source: DatabaseEndpoint,
        destination: ObjectCopyDestination,
        objects: [ObjectCopySelection],
        content: ObjectCopyContent,
        existingPolicy: ObjectCopyExistingPolicy,
        errorHandling: ImportErrorHandling = .stopAndRollback,
        wrapEachTableInTransaction: Bool = true
    ) {
        self.source = source
        self.destination = destination
        self.objects = objects
        self.content = content
        self.existingPolicy = existingPolicy
        self.errorHandling = errorHandling
        self.wrapEachTableInTransaction = wrapEachTableInTransaction
    }

    internal var target: DatabaseEndpoint { destination.endpoint }

    internal var tables: [ObjectCopySelection] {
        objects.filter { $0.kind.carriesRows }
    }

    internal var sourceDefinedObjects: [ObjectCopySelection] {
        objects.filter { $0.kind.isSourceDefined }
    }
}
