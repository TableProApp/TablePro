//
//  JSONExportModels.swift
//  JSONExportPlugin
//

import Foundation

/// How the rows are laid out in the file.
public enum JSONExportLayout: String, Codable, CaseIterable, Sendable, Identifiable {
    /// One object per table, each holding an array of rows. The whole file is one JSON value.
    case object
    /// One row per line, with no wrapping array. A stream reader can process it a line at a time,
    /// and a file too large to hold in memory stays readable.
    case newlineDelimited

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .object: return String(localized: "One JSON object")
        case .newlineDelimited: return String(localized: "One row per line (NDJSON)")
        }
    }

    public var fileExtension: String {
        switch self {
        case .object: return "json"
        case .newlineDelimited: return "ndjson"
        }
    }
}

public struct JSONExportOptions: Equatable, Codable {
    public var prettyPrint: Bool = true
    public var includeNullValues: Bool = true
    public var preserveAllAsStrings: Bool = false
    public var layout: JSONExportLayout = .object

    public init() {}

    /// A synthesized `init(from:)` throws `keyNotFound` for a key the saved payload predates and
    /// never falls back to the property's default, so adding one here would reset the options a
    /// user had already chosen.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = JSONExportOptions()
        prettyPrint = try container.decodeIfPresent(Bool.self, forKey: .prettyPrint) ?? defaults.prettyPrint
        includeNullValues = try container.decodeIfPresent(Bool.self, forKey: .includeNullValues)
            ?? defaults.includeNullValues
        preserveAllAsStrings = try container.decodeIfPresent(Bool.self, forKey: .preserveAllAsStrings)
            ?? defaults.preserveAllAsStrings
        layout = try container.decodeIfPresent(JSONExportLayout.self, forKey: .layout) ?? defaults.layout
    }
}
