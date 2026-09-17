//
//  SQLExportModels.swift
//  SQLExportPlugin
//

import Foundation

public struct SQLExportOptions: Equatable, Codable {
    public var compressWithGzip: Bool = false
    public var batchSize: Int = 500
    public var excludeAutoIncrementValue: Bool = true
    public var excludeDefiner: Bool = true
    public var insertMode: SQLExportInsertMode = .insert

    /// Reads every table inside one transaction at a repeatable snapshot, so a dump of several
    /// tables is consistent with itself. Off by default because it holds a transaction open for the
    /// whole export, which on a busy server keeps the undo log growing.
    public var consistentSnapshot: Bool = false

    /// Starts a new file every `splitSizeMegabytes` megabytes, numbering them `.part1`, `.part2`.
    /// Zero writes one file however large it gets.
    public var splitSizeMegabytes: Int = 0

    /// Closes an `INSERT` once it would pass this many bytes, whichever of this and `batchSize` comes
    /// first. Zero bounds a statement by `batchSize` alone, which is what the export used to do.
    ///
    /// A mebibyte by default, which is under every `max_allowed_packet` a MySQL or MariaDB server has
    /// shipped with this decade and is what `mysqldump` and HeidiSQL both settle on. Stored as bytes
    /// because that is the unit the budget compares against, so no factor is applied at the use site.
    public var maxStatementBytes: Int = 1_048_576

    public init() {}

    /// A synthesized `init(from:)` throws `keyNotFound` for a key the saved payload predates, and
    /// never falls back to the property's default, so every option added here would silently reset
    /// the ones a user had already chosen.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SQLExportOptions()
        compressWithGzip = try container.decodeIfPresent(Bool.self, forKey: .compressWithGzip)
            ?? defaults.compressWithGzip
        batchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? defaults.batchSize
        excludeAutoIncrementValue = try container.decodeIfPresent(Bool.self, forKey: .excludeAutoIncrementValue)
            ?? defaults.excludeAutoIncrementValue
        excludeDefiner = try container.decodeIfPresent(Bool.self, forKey: .excludeDefiner)
            ?? defaults.excludeDefiner
        insertMode = try container.decodeIfPresent(SQLExportInsertMode.self, forKey: .insertMode)
            ?? defaults.insertMode
        consistentSnapshot = try container.decodeIfPresent(Bool.self, forKey: .consistentSnapshot)
            ?? defaults.consistentSnapshot
        splitSizeMegabytes = try container.decodeIfPresent(Int.self, forKey: .splitSizeMegabytes)
            ?? defaults.splitSizeMegabytes
        maxStatementBytes = try container.decodeIfPresent(Int.self, forKey: .maxStatementBytes)
            ?? defaults.maxStatementBytes
    }
}

/// Why an object's definition could not be written.
///
/// Several drivers answer an unreadable definition with an empty string rather than throwing: a
/// SQL Server view created `WITH ENCRYPTION`, or one the connected login cannot see, returns no
/// row and reads back as "". Writing that put a bare `;` under the object's comment banner and
/// reported a clean export, so the guard turns it into a failure the summary names.
/// `CustomStringConvertible` as well as `LocalizedError`, because the warning the export writes
/// into the dump interpolates the error value itself. Without it the comment read
/// `failed to fetch DDL for table orders: emptyDefinition`, the case name.
internal enum SQLExportObjectError: LocalizedError, CustomStringConvertible {
    case emptyDefinition

    internal var errorDescription: String? {
        String(localized: "the server returned no definition", bundle: .main)
    }

    internal var description: String {
        errorDescription ?? ""
    }
}
