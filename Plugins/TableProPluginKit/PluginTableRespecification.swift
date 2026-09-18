//
//  PluginTableRespecification.swift
//  TableProPluginKit
//

import Foundation

/// The table a save wants, expressed as the edits that get there from the table that exists.
///
/// An engine whose `ALTER TABLE` can express every edit never sees one of these: it gets a
/// statement per change and runs them in order. This exists for an engine that has to recreate the
/// table to change it at all, where "a statement per change" is not available and the edits have
/// to be applied together, to one definition, in one transaction.
///
/// It is deliberately a set of edits rather than a finished table definition. A rebuild reproduces
/// the table from the statement the engine stored, so every column the save does not touch keeps
/// its own source text and with it the `CHECK`, `COLLATE`, `GENERATED ALWAYS AS` and comma-bearing
/// `DEFAULT` that no catalog query reports. Handing over a finished definition would mean
/// re-rendering all of them from a model that cannot carry them.
/// A change to one existing column that no `ALTER TABLE` can express.
///
/// A nil field is left exactly as it was, which is not the same as an empty one: nil means "do not
/// touch the type", an empty string means "remove the type". The difference matters because a
/// default read back from a catalog query is not the default the user wrote, so an untouched one
/// must come from the stored text rather than be re-rendered from a model.
public struct PluginColumnAlteration: Sendable, Equatable {
    public let column: String
    public let type: String?
    public let isNullable: Bool?
    public let defaultValue: String?

    public init(column: String, type: String? = nil, isNullable: Bool? = nil, defaultValue: String? = nil) {
        self.column = column
        self.type = type
        self.isNullable = isNullable
        self.defaultValue = defaultValue
    }
}

public struct PluginTableRespecification: Sendable {
    /// Columns to create, which have no stored text to preserve and so are rendered by the driver.
    public let addedColumns: [PluginColumnDefinition]

    /// Columns to remove, by their current names.
    public let droppedColumns: [String]

    /// Current name to wanted name, for the columns a save renames.
    public let renamedColumns: [String: String]

    /// The wanted column order by final name, or nil to leave the order alone.
    public let columnOrder: [String]?

    /// Existing columns whose type, nullability or default changes.
    public let alteredColumns: [PluginColumnAlteration]

    public let addedForeignKeys: [PluginForeignKeyDefinition]

    /// The keys to remove. Matched on the relationship they describe rather than on their names,
    /// because an engine may not store a name for one at all.
    public let droppedForeignKeys: [PluginForeignKeyDefinition]

    public init(
        addedColumns: [PluginColumnDefinition] = [],
        droppedColumns: [String] = [],
        renamedColumns: [String: String] = [:],
        columnOrder: [String]? = nil,
        addedForeignKeys: [PluginForeignKeyDefinition] = [],
        droppedForeignKeys: [PluginForeignKeyDefinition] = [],
        alteredColumns: [PluginColumnAlteration]
    ) {
        self.addedColumns = addedColumns
        self.droppedColumns = droppedColumns
        self.renamedColumns = renamedColumns
        self.columnOrder = columnOrder
        self.addedForeignKeys = addedForeignKeys
        self.droppedForeignKeys = droppedForeignKeys
        self.alteredColumns = alteredColumns
    }

    /// The initializer as it shipped before a respecification could alter a column.
    ///
    /// Kept at its exact original signature: adding the parameter to it would replace its mangled
    /// symbol and stop every plugin built against the earlier PluginKit loading, which is how
    /// 0.49.0 took every registry plugin down.
    @_disfavoredOverload
    public init(
        addedColumns: [PluginColumnDefinition] = [],
        droppedColumns: [String] = [],
        renamedColumns: [String: String] = [:],
        columnOrder: [String]? = nil,
        addedForeignKeys: [PluginForeignKeyDefinition] = [],
        droppedForeignKeys: [PluginForeignKeyDefinition] = []
    ) {
        self.init(
            addedColumns: addedColumns,
            droppedColumns: droppedColumns,
            renamedColumns: renamedColumns,
            columnOrder: columnOrder,
            addedForeignKeys: addedForeignKeys,
            droppedForeignKeys: droppedForeignKeys,
            alteredColumns: []
        )
    }

    public var isEmpty: Bool {
        addedColumns.isEmpty && droppedColumns.isEmpty && renamedColumns.isEmpty
            && columnOrder == nil && addedForeignKeys.isEmpty && droppedForeignKeys.isEmpty
            && alteredColumns.isEmpty
    }

    /// A name this save would make the recreated table hold twice, if there is one.
    ///
    /// A dropped column stays in the recreated table until its own `ALTER TABLE` runs afterwards,
    /// so a save that frees a name and takes it in the same breath cannot be expressed as one
    /// rebuild: renaming `a` to `b` while dropping the existing `b`, or dropping `b` and adding a
    /// new `b`, both put the name in the definition twice. Each is valid as two saves.
    public var namingConflict: String? {
        let retained = droppedColumns.map { $0.lowercased() }
        guard !retained.isEmpty else { return nil }
        let taken = renamedColumns.values.map { $0.lowercased() } + addedColumns.map { $0.name.lowercased() }
        return retained.first { taken.contains($0) }
    }

    /// Whether this respecification rewrites a column's declared type, which re-coerces every
    /// stored value in it through the new affinity.
    public var retypesAColumn: Bool { alteredColumns.contains { $0.type != nil } }

    /// The same respecification as the new table is actually built, for an engine that renames and
    /// drops after rebuilding rather than inside the new definition.
    ///
    /// Two things move. A save names its columns as it wants them to end up, so a foreign key added
    /// onto a column the same save renames arrives under a name the table does not have yet, and is
    /// mapped back. And a dropped column stays in the new table, because the drop runs as its own
    /// `ALTER TABLE` afterwards; leaving it out here would make that statement fail with
    /// `no such column`.
    ///
    /// `alteredColumns` is deliberately not mapped. It is recorded against the column as it stands
    /// now, and mapping it would send an alteration to the wrong column whenever a save swaps two
    /// names around.
    public func namedAsBuilt(using currentNames: [String: String]) -> PluginTableRespecification {
        func asBuilt(_ name: String) -> String { currentNames[name.lowercased()] ?? name }

        return PluginTableRespecification(
            addedColumns: addedColumns,
            droppedColumns: [],
            renamedColumns: [:],
            columnOrder: columnOrder.map { $0.map(asBuilt) },
            addedForeignKeys: addedForeignKeys.map { key in
                PluginForeignKeyDefinition(
                    name: key.name,
                    columns: key.columns.map(asBuilt),
                    referencedTable: key.referencedTable,
                    referencedColumns: key.referencedColumns,
                    onDelete: key.onDelete,
                    onUpdate: key.onUpdate,
                    referencedSchema: key.referencedSchema
                )
            },
            droppedForeignKeys: droppedForeignKeys,
            alteredColumns: alteredColumns
        )
    }

    /// Whether this respecification changes the table's foreign keys, which is what decides whether
    /// the rebuild has to re-check the rows against them.
    public var touchesForeignKeys: Bool {
        !addedForeignKeys.isEmpty || !droppedForeignKeys.isEmpty
    }
}
