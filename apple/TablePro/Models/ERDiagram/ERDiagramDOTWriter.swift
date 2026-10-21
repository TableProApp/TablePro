import Foundation

enum ERDiagramDOTWriter {
    private static let secondaryColor = "#6E6E73"
    private static let headerColor = "#EFEFF4"

    static func document(for graph: ERDiagramGraph) -> String {
        let nodes = ERDiagramExportOrder.nodes(of: graph)
        var ports: [String: Set<String>] = [:]
        for node in nodes {
            ports[node.tableName] = Set(node.displayColumns.map(\.name).filter(isPortable))
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
                lines.append("            <TR>\(cell(for: column))</TR>")
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
    private static func cell(for column: ERColumnDisplay) -> String {
        let port = isPortable(column.name) ? " PORT=\"\(html(column.name))\"" : ""
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
    private static func endpoint(_ table: String, column: String, ports: [String: Set<String>]) -> String {
        guard ports[table]?.contains(column) == true else { return quoted(table) }
        return "\(quoted(table)):\(quoted(column))"
    }

    // DOT keeps an escaped backslash doubled, so such a port reference never matches its PORT.
    private static func isPortable(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("\\")
    }

    static func quoted(_ id: String) -> String {
        let escaped = id
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // Graphviz parses a label as XML, so a character XML cannot hold becomes U+FFFD.
    static func html(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
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
