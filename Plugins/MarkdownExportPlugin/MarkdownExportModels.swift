//
//  MarkdownExportModels.swift
//  MarkdownExportPlugin
//

import Foundation

public struct MarkdownExportOptions: Equatable, Codable {
    /// Pads every cell so the columns line up in the raw text. Off writes the narrowest table a
    /// renderer still reads correctly, which is what a large result wants.
    public var alignsColumns: Bool = true

    /// Writes each table's name as a heading above its table.
    public var includesTableNames: Bool = true

    /// What a null cell reads as. Empty is ambiguous in Markdown, where an empty cell and a cell
    /// holding an empty string render the same.
    public var nullPlaceholder: String = "NULL"

    public init() {}

    /// A synthesized `init(from:)` throws `keyNotFound` for a key the saved payload predates and
    /// never falls back to the property's default, so adding one would reset what a user chose.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MarkdownExportOptions()
        alignsColumns = try container.decodeIfPresent(Bool.self, forKey: .alignsColumns)
            ?? defaults.alignsColumns
        includesTableNames = try container.decodeIfPresent(Bool.self, forKey: .includesTableNames)
            ?? defaults.includesTableNames
        nullPlaceholder = try container.decodeIfPresent(String.self, forKey: .nullPlaceholder)
            ?? defaults.nullPlaceholder
    }
}

/// Renders GitHub-flavoured Markdown tables.
///
/// Pure and separate from the plugin so the escaping is testable without a database: a value
/// holding a pipe or a line break has to be neutralised or it ends the cell early and every column
/// after it shifts.
public enum MarkdownTableRenderer {
    /// A pipe closes a cell and a line break closes a row, so both are replaced rather than
    /// escaped: `\|` works in GitHub's renderer and in few others, and no renderer accepts a raw
    /// newline inside a cell.
    public static func cell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    public static func row(_ cells: [String], widths: [Int]?) -> String {
        guard let widths, widths.count == cells.count else {
            return "| \(cells.joined(separator: " | ")) |"
        }
        let padded = zip(cells, widths).map { cell, width in
            cell.padding(toLength: max(width, cell.count), withPad: " ", startingAt: 0)
        }
        return "| \(padded.joined(separator: " | ")) |"
    }

    public static func separator(columnCount: Int, widths: [Int]?) -> String {
        let dashes = (0 ..< columnCount).map { index -> String in
            let width = widths?[safe: index] ?? 3
            return String(repeating: "-", count: max(3, width))
        }
        return "| \(dashes.joined(separator: " | ")) |"
    }

    /// Column widths from the header and a sample of rows. A width taken from every row of a
    /// million-row table would mean holding the table in memory to align it.
    public static func widths(header: [String], sample: [[String]]) -> [Int] {
        var widths = header.map { $0.count }
        for row in sample {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        return widths
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
