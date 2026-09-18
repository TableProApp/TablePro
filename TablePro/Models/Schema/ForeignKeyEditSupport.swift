//
//  ForeignKeyEditSupport.swift
//  TablePro
//

import Foundation

/// How an engine adds and drops a table's foreign keys.
///
/// Separate from `supportsForeignKeys`, which answers a different question. That flag means the
/// engine *has* foreign keys, which is what decides whether the Structure tab shows the list at
/// all. Reading it as permission to edit them is what let SQLite offer an enabled "+" over a
/// driver with no statement behind it, so the save failed with "Unsupported schema operation" after
/// the user had filled the row in.
enum ForeignKeyEditSupport: Sendable, Equatable {
    /// `ALTER TABLE … ADD CONSTRAINT … FOREIGN KEY` and `DROP CONSTRAINT`, which change the catalog
    /// and read no row.
    case alter

    /// No statement can add or drop one, so the table is recreated with the keys the save asks for
    /// and its rows copied across. SQLite and its derivatives are the case: measured against 3.54,
    /// `ADD CONSTRAINT … FOREIGN KEY` is a syntax error and `DROP CONSTRAINT` on a foreign key
    /// answers "constraint may not be dropped". The script is reviewed and confirmed before it runs.
    case rebuild

    case unsupported

    var isEditable: Bool { self != .unsupported }
}

/// Whether the Structure tab may offer a foreign key edit right now, and what to say when it may
/// not.
///
/// Pure and exhaustive so the affordance and its explanation come from one place. Splitting them is
/// what shipped the reported bug: the "+" was offered on every engine with foreign keys, while
/// whether anything could come of it was decided much later, by a driver that returned nil.
enum ForeignKeyEditAvailability: Sendable, Equatable {
    case available(ForeignKeyEditSupport)

    /// Withheld where the user would reasonably expect to be able to edit, so the reason is shown.
    case unavailable(reason: String)

    var support: ForeignKeyEditSupport? {
        if case .available(let support) = self { return support }
        return nil
    }

    var isAvailable: Bool { support != nil }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// The same answer in the vocabulary the rest of the Structure tab speaks, so one gate can hand
    /// every call site a single type while this policy stays the owner of the foreign key wording.
    var structureEditAvailability: StructureEditAvailability {
        switch self {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        }
    }
}

enum ForeignKeyEditPolicy {
    /// - Parameter kindRefusal: Why the object's own kind refuses a foreign key edit, nil when it
    ///   accepts one. Supplied by `StructureEditEligibility`, because only the per-kind matrix knows
    ///   which of seven object kinds is in front of the user. This used to be an `isTable` Bool
    ///   derived from `allowsRowEditing`, which is true for a materialized view, so the "+" was
    ///   offered over an `ADD CONSTRAINT` PostgreSQL always refuses. (#2726)
    static func resolve(
        support: ForeignKeyEditSupport,
        engineName: String,
        kindRefusal: String?,
        canEditSchema: Bool
    ) -> ForeignKeyEditAvailability {
        guard canEditSchema else {
            return .unavailable(
                reason: String(format: String(localized: "%@ cannot edit a table's structure."), engineName)
            )
        }
        /// Both mechanisms emit table DDL. The rebuild one looks the table up by
        /// `sqlite_master.type = 'table'`, so anything else would end in an error rather than an
        /// explanation.
        if let kindRefusal {
            return .unavailable(reason: kindRefusal)
        }
        switch support {
        case .unsupported:
            return .unavailable(
                reason: String(
                    format: String(localized: "%@ cannot add or remove a table's foreign keys."),
                    engineName
                )
            )
        case .alter, .rebuild:
            return .available(support)
        }
    }
}

/// How an engine performs the structure edits its `ALTER TABLE` cannot express directly.
///
/// One value rather than a field per capability, because every one of them has to be carried
/// through each of `PluginMetadataSnapshot`'s copying helpers by hand, and a capability a helper
/// forgets is silently reset to unsupported rather than failing to compile. Grouping them means a
/// new capability needs no new call site, and `PluginMetadataSnapshotCopyTests` holds the helpers
/// to carrying this one.
struct SchemaEditingSupport: Sendable, Equatable {
    var columnReorder: ColumnReorderSupport = .unsupported
    var foreignKeyEdit: ForeignKeyEditSupport = .unsupported

    /// Which structure edits each kind of object accepts. Defaults to tables only, so an engine
    /// nobody has curated never offers a view, materialized view or foreign table an edit its server
    /// would refuse.
    var structureEdits: StructureObjectEditMatrix = .tablesOnly
}
