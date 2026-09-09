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
public struct PluginTableRespecification: Sendable {
    /// Columns to create, which have no stored text to preserve and so are rendered by the driver.
    public let addedColumns: [PluginColumnDefinition]

    /// Columns to remove, by their current names.
    public let droppedColumns: [String]

    /// Current name to wanted name, for the columns a save renames.
    public let renamedColumns: [String: String]

    /// The wanted column order by final name, or nil to leave the order alone.
    public let columnOrder: [String]?

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
        droppedForeignKeys: [PluginForeignKeyDefinition] = []
    ) {
        self.addedColumns = addedColumns
        self.droppedColumns = droppedColumns
        self.renamedColumns = renamedColumns
        self.columnOrder = columnOrder
        self.addedForeignKeys = addedForeignKeys
        self.droppedForeignKeys = droppedForeignKeys
    }

    public var isEmpty: Bool {
        addedColumns.isEmpty && droppedColumns.isEmpty && renamedColumns.isEmpty
            && columnOrder == nil && addedForeignKeys.isEmpty && droppedForeignKeys.isEmpty
    }

    /// Whether this respecification changes the table's foreign keys, which is what decides whether
    /// the rebuild has to re-check the rows against them.
    public var touchesForeignKeys: Bool {
        !addedForeignKeys.isEmpty || !droppedForeignKeys.isEmpty
    }
}
