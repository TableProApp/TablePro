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
    }
}
