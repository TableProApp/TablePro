//
//  DataDictionaryHTMLRenderer.swift
//  DataDictionaryExportPlugin
//

import Foundation
import TableProPluginKit

// One file with its style inline and no script, so it opens, mails and prints the same anywhere.
enum DataDictionaryHTMLRenderer {
    static func render(_ document: DataDictionaryDocument) -> String {
        var html = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="light dark">
            <title>\(escape(document.title))</title>
            <style>
            \(style)
            </style>
            </head>
            <body>
            <header>
            <h1>\(escape(document.title))</h1>
            <p class="summary">\(escape(document.summary()))</p>
            </header>

            """
        if !document.objects.isEmpty {
            html += "<nav id=\"\(DataDictionaryAnchors.contents)\">\n<h2>Contents</h2>\n<ol>\n"
            for index in document.objects.indices {
                let object = document.objects[index]
                let kind = object.kind == .table ? "" : " <span class=\"kind\">\(escape(object.kindLabel.lowercased()))</span>"
                html += "<li><a href=\"#\(document.anchors[index])\"><code>\(escape(document.displayName(at: index)))</code></a>\(kind)</li>\n"
            }
            html += "</ol>\n</nav>\n"
        }
        for index in document.objects.indices {
            html += section(at: index, in: document)
        }
        html += "</body>\n</html>\n"
        return html
    }

    private static func section(at index: Int, in document: DataDictionaryDocument) -> String {
        let object = document.objects[index]
        var html = "<section id=\"\(document.anchors[index])\">\n"
        html += "<h2><code>\(escape(document.displayName(at: index)))</code></h2>\n"
        html += "<p><span class=\"kind\">\(escape(object.kindLabel)).</span>"
        if let comment = object.comment {
            html += " \(escape(comment))"
        } else if let error = object.commentError {
            html += " <span class=\"error\">Comment could not be read: \(escape(error))</span>"
        }
        html += "</p>\n"

        if let error = object.columnsError {
            html += "<p class=\"error\">Columns could not be read: \(escape(error))</p>\n"
        } else if object.columns.isEmpty {
            html += "<p>No columns listed.</p>\n"
        } else {
            html += columnTable(document.columnRows(at: index), in: document)
        }

        let indexes = document.indexRows(at: index)
        if let error = object.indexesError {
            html += "<h3>Indexes</h3>\n<p class=\"error\">Indexes could not be read: \(escape(error))</p>\n"
        } else if !indexes.isEmpty {
            html += "<h3>Indexes</h3>\n"
            html += table(
                header: ["Name", "Columns", "Kind", "Method"],
                rows: indexes.map { ["<code>\(escape($0.name))</code>", "<code>\(escape($0.columns))</code>", escape($0.kind), escape($0.method)] }
            )
        }

        let keys = document.foreignKeyRows(at: index)
        if let error = object.foreignKeysError {
            html += "<h3>Foreign keys</h3>\n<p class=\"error\">Foreign keys could not be read: \(escape(error))</p>\n"
        } else if !keys.isEmpty {
            html += "<h3>Foreign keys</h3>\n"
            html += table(
                header: ["Name", "Columns", "References", "On delete", "On update"],
                rows: keys.map { key in
                    [
                        "<code>\(escape(key.name))</code>",
                        key.columns.map { "<code>\(escape($0))</code>" }.joined(separator: ", "),
                        "\(link(key.target)) (\(key.referencedColumns.map { "<code>\(escape($0))</code>" }.joined(separator: ", ")))",
                        escape(key.onDelete),
                        escape(key.onUpdate)
                    ]
                }
            )
        }
        html += "</section>\n"
        return html
    }

    private static func columnTable(_ rows: [DataDictionaryColumnRow], in document: DataDictionaryDocument) -> String {
        var header = ["Column", "Type", "Nullable"]
        if document.showsDefault { header.append("Default") }
        if document.showsKey { header.append("Key") }
        if document.showsReferences { header.append("References") }
        if document.showsColumnComment { header.append("Comment") }
        let cells = rows.map { row -> [String] in
            var cells = ["<code>\(escape(row.name))</code>", "<code>\(escape(row.type))</code>", row.isNullable ? "Yes" : "No"]
            if document.showsDefault { cells.append(row.defaultText.map { "<code>\(escape($0))</code>" } ?? "") }
            if document.showsKey { cells.append(row.isPrimaryKey ? "PK" : "") }
            if document.showsReferences { cells.append(row.references.map { link($0) }.joined(separator: ", ")) }
            if document.showsColumnComment { cells.append(row.comment.map(escape) ?? "") }
            return cells
        }
        return table(header: header, rows: cells)
    }

    private static func table(header: [String], rows: [[String]]) -> String {
        var html = "<table>\n<thead><tr>"
        html += header.map { "<th>\(escape($0))</th>" }.joined()
        html += "</tr></thead>\n<tbody>\n"
        for row in rows {
            html += "<tr>" + row.map { "<td>\($0)</td>" }.joined() + "</tr>\n"
        }
        html += "</tbody>\n</table>\n"
        return html
    }

    private static func link(_ reference: DataDictionaryReference) -> String {
        let label = "<code>\(escape(reference.text))</code>"
        guard let anchor = reference.anchor else { return label }
        return "<a href=\"#\(escape(anchor))\">\(label)</a>"
    }

    static func escape(_ value: String) -> String {
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

    private static let style = """
        :root { color-scheme: light dark; --text: #1d1d1f; --muted: #6e6e73; --rule: #d2d2d7; --head: #f5f5f7; --link: #0066cc; }
        @media (prefers-color-scheme: dark) {
          :root { --text: #f5f5f7; --muted: #a1a1a6; --rule: #424245; --head: #1c1c1e; --link: #4da3ff; }
          body { background: #000; }
        }
        body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; color: var(--text); margin: 32px auto; max-width: 1100px; padding: 0 16px; }
        h1 { font-size: 26px; margin: 0 0 4px; }
        h2 { font-size: 19px; margin: 32px 0 6px; }
        h3 { font-size: 15px; margin: 18px 0 6px; }
        .summary, .kind { color: var(--muted); }
        .error { color: #c9252d; }
        a { color: var(--link); text-decoration: none; }
        code { font: 12.5px/1.4 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; overflow-wrap: anywhere; }
        nav ol { columns: 2 260px; padding-left: 20px; }
        table { border-collapse: collapse; width: 100%; margin: 6px 0 12px; }
        th, td { border: 1px solid var(--rule); padding: 4px 8px; text-align: left; vertical-align: top; }
        th { background: var(--head); font-weight: 600; }
        @media print {
          :root { --text: #000; --muted: #444; --rule: #999; --head: #eee; --link: #000; }
          body { background: #fff; margin: 0; max-width: none; font-size: 10.5pt; }
          code { font-size: 9.5pt; }
          nav ol { columns: 2; }
          h2, h3 { break-after: avoid; }
          thead { display: table-header-group; }
          tr { break-inside: avoid; }
        }
        """
}
