//
//  PluginRowWriteContext.swift
//  TableProPluginKit
//

import Foundation

/// What the host knows about a table that a driver writing its own statements cannot learn from the changes alone.
///
/// The host reads these from the table's schema. A driver that kept its own copy learned them only on whichever
/// connection happened to fetch the columns, which for a pooled metadata read is never the one that saves.
///
/// Deliberately not `@frozen`, and every field is a `var` with an empty default set through `init()`, so a later
/// field is one more property rather than a second initializer every already-built plugin would have to find.
public struct PluginRowWriteContext: Sendable, Equatable {
    /// Columns the server refuses a written value for: generated and computed columns, `GENERATED ALWAYS` identity,
    /// SQL Server `IDENTITY`, `rowversion` and period columns. The host never stages a value for one, so a change that
    /// names one is refused rather than sent.
    public var serverOwnedColumns: Set<String> = []

    /// Columns a keyless row match cannot compare at all. A keyless change that would need one is refused, because a
    /// match with a column left out can pick a different row.
    public var rowMatchExcludedColumns: Set<String> = []

    /// Columns a keyless row match compares through the server's own conversion, because the value the grid read does
    /// not compare equal to the column as stored.
    public var rowMatchTextColumns: Set<String> = []

    public init() {}
}
