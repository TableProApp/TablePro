import Foundation

enum ERDiagramDOTWriter {
    private static let secondaryColor = "#6E6E73"
    private static let headerColor = "#EFEFF4"

    static func document(for graph: ERDiagramGraph) -> String {
        let nodes = ERDiagramExportOrder.nodes(of: graph)
        var ports: [String: [String: String]] = [:]
        for node in nodes {
            let all = portIds(for: node.columns.map(\.name))
            ports[node.tableName] = all.filter { name, _ in node.displayColumns.contains { $0.name == name } }
        }

        var lines = [
            "digraph \"ER Diagram\" {",
            "    graph [rankdir=LR, nodesep=0.5, ranksep=1.2];",
            "    node [shape=plain, fontname=\"Helvetica\", fontsize=11];",
            "    edge [dir=both, color=\"\(secondaryColor)\", arrowsize=0.8];",
        ]

        for node in nodes {
            lines.append("")
            lines.append("    \(quoted(node.tableName)) [label=<")
            lines.append("        <TABLE BORDER=\"1\" CELLBORDER=\"0\" CELLSPACING=\"0\" CELLPADDING=\"4\">")
            lines.append(
                "            <TR><TD ALIGN=\"LEFT\" BGCOLOR=\"\(headerColor)\"><B>\(html(node.tableName))</B></TD></TR>"
            )
            for column in node.displayColumns {
                lines.append("            <TR>\(cell(for: column, port: ports[node.tableName]?[column.name]))</TR>")
            }
            lines.append("        </TABLE>")
            lines.append("    >];")
        }

        let edges = ERDiagramExportOrder.edges(of: graph)
        if !edges.isEmpty {
            lines.append("")
        }
        for edge in edges {
            let tail = endpoint(edge.fromTable, column: edge.fromColumn, ports: ports)
            let head = endpoint(edge.toTable, column: edge.toColumn, ports: ports)
            let (tailArrow, headArrow) = arrows(edge.cardinality)
            lines.append("    \(tail) -> \(head) [arrowtail=\(tailArrow), arrowhead=\(headArrow)];")
        }

        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    // Graphviz puts the first shape against the table, as the canvas puts the crow or outer bar.
    static func arrows(_ cardinality: ERCardinality) -> (tail: String, head: String) {
        switch cardinality {
        case .oneToOne: return ("teetee", "tee")
        case .zeroOrOneToOne: return ("teeodot", "tee")
        case .manyToOne: return ("crowtee", "tee")
        case .zeroOrManyToOne: return ("crowodot", "tee")
        case .manyToMany: return ("crow", "crow")
        }
    }

    // One cell per row keeps the port as wide as the table, so an edge stops at the border.
    private static func cell(for column: ERColumnDisplay, port: String?) -> String {
        let port = port.map { " PORT=\"\($0)\"" } ?? ""
        var text = html(column.name)
        if !column.dataType.isEmpty {
            text += " <FONT COLOR=\"\(secondaryColor)\">\(html(column.dataType))</FONT>"
        }
        let keys = [column.isPrimaryKey ? "PK" : nil, column.isForeignKey ? "FK" : nil].compactMap { $0 }
        if !keys.isEmpty {
            text += " <FONT COLOR=\"\(secondaryColor)\" POINT-SIZE=\"9\">\(keys.joined(separator: ", "))</FONT>"
        }
        return "<TD ALIGN=\"LEFT\"\(port)>\(text)</TD>"
    }

    // A column the view hides, or a many-to-many edge, has no port: the edge meets the table.
    private static func endpoint(_ table: String, column: String, ports: [String: [String: String]]) -> String {
        guard let port = ports[table]?[column] else { return quoted(table) }
        return "\(quoted(table)):\(quoted(port))"
    }

    // Graphviz splits a port reference at `:` into port and compass point, even quoted, and keeps an
    // escaped backslash doubled, so a port is the name cut to `[A-Za-z0-9_]`, unique per table.
    static func portIds(for columns: [String]) -> [String: String] {
        var ids: [String: String] = [:]
        var taken: Set<String> = []
        for name in columns where ids[name] == nil {
            let base = name.unicodeScalars.reduce(into: "") { result, scalar in
                let isWord = scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_")
                if isWord {
                    result.unicodeScalars.append(scalar)
                } else if !result.hasSuffix("_") {
                    result.append("_")
                }
            }
            var candidate = base.isEmpty ? "_" : base
            var suffix = 2
            while taken.contains(candidate) {
                candidate = "\(base)_\(suffix)"
                suffix += 1
            }
            taken.insert(candidate)
            ids[name] = candidate
        }
        return ids
    }

    static func quoted(_ id: String) -> String {
        let escaped = id
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // Graphviz expands `\N` and `\G` even in an HTML label, so a backslash is doubled.
    static func html(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t", "\n", "\r": result += " "
            default:
                let value = scalar.value
                let allowed = (0x20...0xD7FF).contains(value) || (0xE000...0xFFFD).contains(value) || value >= 0x10000
                result.unicodeScalars.append(allowed ? scalar : "\u{FFFD}")
            }
        }
        return result
    }
}
