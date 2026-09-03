//
//  ParquetExportModels.swift
//  ParquetExportPlugin
//

import Foundation

public enum ParquetCompression: String, Codable, CaseIterable, Sendable, Identifiable {
    case snappy
    case zstd
    case gzip
    case uncompressed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .snappy: return String(localized: "Snappy")
        case .zstd: return String(localized: "Zstd")
        case .gzip: return String(localized: "Gzip")
        case .uncompressed: return String(localized: "None")
        }
    }

    /// The spelling DuckDB's `COPY` takes. Uppercase because the option is compared
    /// case-insensitively but reads as a constant in the generated statement.
    public var duckDBValue: String { rawValue.uppercased() }
}

public struct ParquetExportOptions: Equatable, Codable {
    /// Snappy is the default every Parquet reader supports. Zstd is smaller and needs a reader
    /// built with it, which most modern ones are and some older Hadoop stacks are not.
    public var compression: ParquetCompression = .snappy

    /// Rows per row group. Larger groups compress better and cost more memory to read; 122,880 is
    /// DuckDB's own default and the value most tools are tuned for.
    public var rowGroupSize: Int = 122_880

    public init() {}

    /// A synthesized `init(from:)` throws `keyNotFound` for a key the saved payload predates and
    /// never falls back to the property's default, so adding one would reset what a user chose.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ParquetExportOptions()
        compression = try container.decodeIfPresent(ParquetCompression.self, forKey: .compression)
            ?? defaults.compression
        rowGroupSize = try container.decodeIfPresent(Int.self, forKey: .rowGroupSize)
            ?? defaults.rowGroupSize
    }
}
