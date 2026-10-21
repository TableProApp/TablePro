//
//  DataDictionaryMarkdownRenderer.swift
//  DataDictionaryExportPlugin
//

import Foundation
import TableProPluginKit

enum DataDictionaryMarkdownRenderer {
    static func render(_ document: DataDictionaryDocument) -> String {
        var lines = ["# \(text(document.title))", "", text(document.summary()), ""]
        if !document.objects.isEmpty {
            lines += ["<a id=\"\(DataDictionaryAnchors.contents)\"></a>", "", "## Contents", ""]
            for index in document.objects.indices {
                let object = document.objects[index]
                let kind = object.kind == .table ? "" : " (\(object.kindLabel.lowercased()))"
                lines.append("- [\(code(document.displayName(at: index)))](#\(document.anchors[index]))\(kind)")
            }
            lines.append("")
        }
        for index in document.objects.indices {
            lines += section(at: index, in: document)
        }
        return lines.joined(separator: "\n")
    }

    private static func section(at index: Int, in document: DataDictionaryDocument) -> [String] {
        let object = document.objects[index]
        var lines = ["<a id=\"\(document.anchors[index])\"></a>", "", "## \(code(document.displayName(at: index)))", ""]
        if let comment = object.comment {
            lines.append("**\(object.kindLabel).** \(text(comment))")
        } else {
            lines.append("**\(object.kindLabel).**")
        }
        lines.append("")

        if let error = object.columnsError {
            lines += ["Columns could not be read: \(text(error))", ""]
        } else if object.columns.isEmpty {
            lines += ["No columns listed.", ""]
        } else {
            lines += columnTable(document.columnRows(at: index), in: document) + [""]
        }

        let indexes = document.indexRows(at: index)
        if !indexes.isEmpty {
            lines += ["### Indexes", ""]
            lines += table(
                header: ["Name", "Columns", "Kind", "Method"],
                rows: indexes.map { [code($0.name, inTable: true), code($0.columns, inTable: true), $0.kind, text($0.method, inTable: true)] }
            )
            lines.append("")
        }

        let keys = document.foreignKeyRows(at: index)
        if !keys.isEmpty {
            lines += ["### Foreign keys", ""]
            lines += table(
                header: ["Name", "Columns", "References", "On delete", "On update"],
                rows: keys.map { key in
                    [
                        code(key.name, inTable: true),
                        key.columns.map { code($0, inTable: true) }.joined(separator: ", "),
                        "\(link(key.target)) (\(key.referencedColumns.map { code($0, inTable: true) }.joined(separator: ", ")))",
                        text(key.onDelete, inTable: true),
                        text(key.onUpdate, inTable: true)
                    ]
                }
            )
            lines.append("")
        }
        return lines
    }

    private static func columnTable(_ rows: [DataDictionaryColumnRow], in document: DataDictionaryDocument) -> [String] {
        var header = ["Column", "Type", "Nullable"]
        if document.showsDefault { header.append("Default") }
        if document.showsKey { header.append("Key") }
        if document.showsReferences { header.append("References") }
        if document.showsColumnComment { header.append("Comment") }
        let cells = rows.map { row -> [String] in
            var cells = [code(row.name, inTable: true), code(row.type, inTable: true), row.isNullable ? "Yes" : "No"]
            if document.showsDefault { cells.append(row.defaultText.map { code($0, inTable: true) } ?? "") }
            if document.showsKey { cells.append(row.isPrimaryKey ? "PK" : "") }
            if document.showsReferences { cells.append(row.references.map { link($0) }.joined(separator: ", ")) }
            if document.showsColumnComment { cells.append(row.comment.map { text($0, inTable: true) } ?? "") }
            return cells
        }
        return table(header: header, rows: cells)
    }

    private static func table(header: [String], rows: [[String]]) -> [String] {
        let line = { (cells: [String]) in "| " + cells.joined(separator: " | ") + " |" }
        return [line(header), line(header.map { _ in "---" })] + rows.map(line)
    }

    private static func link(_ reference: DataDictionaryReference) -> String {
        let label = code(reference.text, inTable: true)
        guard let anchor = reference.anchor else { return label }
        return "[\(label)](#\(anchor))"
    }

    // A code span shows its content literally, so only its own fence and a table's pipe need care.
    static func code(_ value: String, inTable: Bool = false) -> String {
        var content = flattened(value)
        guard !content.isEmpty else { return "" }
        if inTable { content = content.replacingOccurrences(of: "|", with: "\\|") }
        var longestRun = 0
        var run = 0
        for character in content {
            run = character == "`" ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        let fence = String(repeating: "`", count: longestRun + 1)
        let padded = content.hasPrefix("`") || content.hasSuffix("`") ? " \(content) " : content
        return fence + padded + fence
    }

    static func text(_ value: String, inTable: Bool = false) -> String {
        var escaped = ""
        for character in flattened(value) {
            if "\\`*_[]<>#&".contains(character) || (inTable && character == "|") {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    private static func flattened(_ value: String) -> String {
        value.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).joined(separator: " ")
    }
}
