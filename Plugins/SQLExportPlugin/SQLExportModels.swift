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
    }
}
