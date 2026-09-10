//
//  JSONRowTextRenderer.swift
//  TablePro
//
//  Prints the lines the inspector is showing, for Copy Visible.
//

import Foundation

enum JSONRowTextRenderer {
    static let indent = "  "

    /// Renders exactly what is on screen: a collapsed object prints as `{…}`, a filtered-out key
    /// does not print at all, and an expanded foreign key prints its fetched row.
    static func render(rows: [JSONDisplayRow]) -> String {
        rows.map(line(for:)).joined(separator: "\n")
    }

    private static func line(for row: JSONDisplayRow) -> String {
        let padding = String(repeating: indent, count: row.depth)
        let keyPrefix = row.showsKey ? "\"\(JSONScalarText.escaped(row.key.text ?? ""))\": " : ""
        let comma = row.needsComma ? "," : ""

        switch row.token {
        case .scalar(let scalar):
            return "\(padding)\(keyPrefix)\(JSONScalarText.printed(scalar))\(comma)"
        case .openObject:
            return "\(padding)\(keyPrefix){"
        case .openArray:
            return "\(padding)\(keyPrefix)["
        case .closeObject:
            return "\(padding)}\(comma)"
        case .closeArray:
            return "\(padding)]\(comma)"
        case .collapsedObject:
            return "\(padding)\(keyPrefix){…}\(comma)"
        case .collapsedArray:
            return "\(padding)\(keyPrefix)[…]\(comma)"
        }
    }
}
