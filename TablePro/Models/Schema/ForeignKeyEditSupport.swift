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
}

enum ForeignKeyEditPolicy {
    static func resolve(
        support: ForeignKeyEditSupport,
        engineName: String,
        isTable: Bool,
        canEditSchema: Bool
    ) -> ForeignKeyEditAvailability {
        guard canEditSchema else {
            return .unavailable(
                reason: String(format: String(localized: "%@ cannot edit a table's structure."), engineName)
            )
        }
        /// A view has no constraints of its own, and both mechanisms emit table DDL. The rebuild one
        /// looks the table up by `sqlite_master.type = 'table'`, so a view would end in an error
        /// rather than an explanation.
        guard isTable else {
            return .unavailable(
                reason: String(localized: "A view has no foreign keys. Edit the tables its query reads.")
            )
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
}
