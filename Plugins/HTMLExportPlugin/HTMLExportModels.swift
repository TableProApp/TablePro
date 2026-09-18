//
//  HTMLExportModels.swift
//  HTMLExportPlugin
//

import Foundation

public struct HTMLExportOptions: Equatable, Codable {
    /// Wraps the tables in a full document with a stylesheet. Off writes bare `<table>` elements,
    /// which is what pasting into an existing page wants.
    public var writesFullDocument: Bool = true

    public var includesTableNames: Bool = true

    /// Renders a null as a dimmed `NULL` rather than an empty cell, which is otherwise identical to
    /// a cell holding an empty string.
    public var marksNulls: Bool = true

    public init() {}

    /// A synthesized `init(from:)` throws `keyNotFound` for a key the saved payload predates and
    /// never falls back to the property's default, so adding one would reset what a user chose.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = HTMLExportOptions()
        writesFullDocument = try container.decodeIfPresent(Bool.self, forKey: .writesFullDocument)
            ?? defaults.writesFullDocument
        includesTableNames = try container.decodeIfPresent(Bool.self, forKey: .includesTableNames)
            ?? defaults.includesTableNames
        marksNulls = try container.decodeIfPresent(Bool.self, forKey: .marksNulls) ?? defaults.marksNulls
    }
}

/// Escapes text for HTML.
///
/// Every value in an export comes from the database, so a value holding `<script>` reaches a file
/// someone opens in a browser. Escaping the five markup characters is what keeps the export a table
/// rather than a page that runs what a row happened to contain.
public enum HTMLEscaping {
    public static func text(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
