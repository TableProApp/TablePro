import Foundation

// Names are fitted to the lexer of Mermaid 11.6 and later, which GitHub renders with.
enum ERDiagramMermaidWriter {
    static func document(for graph: ERDiagramGraph) -> String {
        let nodes = ERDiagramExportOrder.nodes(of: graph)
        let names = entityNames(for: nodes.map(\.tableName))
        var lines = ["erDiagram"]

        for node in nodes {
            let name = names[node.tableName] ?? entityName(node.tableName)
            guard !node.displayColumns.isEmpty else {
                lines.append("    \(name)")
                continue
            }
            lines.append("    \(name) {")
            for column in node.displayColumns {
                var line = "        \(attributeWord(column.dataType)) \(attributeWord(column.name))"
                let keys = [column.isPrimaryKey ? "PK" : nil, column.isForeignKey ? "FK" : nil].compactMap { $0 }
                if !keys.isEmpty {
                    line += " " + keys.joined(separator: ", ")
                }
                lines.append(line)
            }
            lines.append("    }")
        }

        for edge in ERDiagramExportOrder.edges(of: graph) {
            let role = edge.cardinality == .manyToMany ? edge.fkName : edge.fromColumn
            lines.append(
                "    \(names[edge.fromTable] ?? entityName(edge.fromTable)) \(relationship(edge.cardinality))"
                    + " \(names[edge.toTable] ?? entityName(edge.toTable))"
                    + " : \(quoted(role))"
            )
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // Fenced, so a paste into GitHub or any Markdown that renders Mermaid draws the diagram.
    static func markdownBlock(for graph: ERDiagramGraph) -> String {
        "```mermaid\n" + document(for: graph) + "```\n"
    }

    // Each end carries the marker the canvas draws there; the foreign key's table is on the left.
    static func relationship(_ cardinality: ERCardinality) -> String {
        switch cardinality {
        case .oneToOne: return "||--||"
        case .zeroOrOneToOne: return "|o--||"
        case .manyToOne: return "}|--||"
        case .zeroOrManyToOne: return "}o--||"
        case .manyToMany: return "}o--o{"
        }
    }

    // Two tables fitted to one name would merge into one entity, so the later one takes a suffix.
    static func entityNames(for tables: [String]) -> [String: String] {
        var names: [String: String] = [:]
        var taken: Set<String> = []
        for table in tables.sorted() {
            let base = fitted(table)
            var candidate = base
            var suffix = 2
            while taken.contains(candidate) {
                candidate = "\(base)_\(suffix)"
                suffix += 1
            }
            taken.insert(candidate)
            names[table] = "\"\(candidate)\""
        }
        return names
    }

    // Quoted, so a keyword (`end`, `one`, `to`) or a space stays a name.
    static func entityName(_ name: String) -> String {
        quoted(name)
    }

    private static func quoted(_ text: String) -> String {
        "\"\(fitted(text))\""
    }

    // The lexer reads `direction LR` anywhere on a line as a directive, quoted or not.
    private static func fitted(_ text: String) -> String {
        let forbidden: Set<Character> = ["\"", "%", "\\", "\r", "\n", "\u{0B}", "\u{08}", "\r\n"]
        let cleaned = text.isEmpty ? "_" : String(text.map { forbidden.contains($0) ? "_" : $0 })
        return cleaned.replacingOccurrences(
            of: "(direction)\\s+(TB|BT|RL|LR)",
            with: "$1_$2",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    // The lexer takes `pk` or `FK-1` for a key, so such a word gets a leading `_`.
    static func attributeWord(_ text: String) -> String {
        var word = ""
        var replacing = false
        for scalar in text.unicodeScalars {
            if isWordScalar(scalar) {
                word.unicodeScalars.append(scalar)
                replacing = false
            } else if !replacing {
                word.append("_")
                replacing = true
            }
        }
        guard let first = word.unicodeScalars.first else { return "_" }
        if !isLeadingScalar(first) || startsWithKey(word) {
            word = "_" + word
        }
        return word
    }

    // The lexer reads UTF-16, so a character past U+FFFF is two units it accepts.
    private static func isLeadingScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x5F: return true
        default: return scalar.value >= 0xC0
        }
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if isLeadingScalar(scalar) { return true }
        switch scalar {
        case "0"..."9", "-", "[", "]", "(", ")": return true
        default: return false
        }
    }

    private static func startsWithKey(_ word: String) -> Bool {
        let lowered = word.lowercased()
        guard ["pk", "fk", "uk"].contains(where: { lowered.hasPrefix($0) }) else { return false }
        guard let next = word.unicodeScalars.dropFirst(2).first else { return true }
        switch next {
        case "a"..."z", "A"..."Z", "0"..."9", "_": return false
        default: return true
        }
    }
}

// Ordered by name only, so an unchanged schema always writes the same file.
enum ERDiagramExportOrder {
    static func nodes(of graph: ERDiagramGraph) -> [ERTableNode] {
        graph.nodes.sorted { $0.tableName < $1.tableName }
    }

    static func edges(of graph: ERDiagramGraph) -> [EREdge] {
        let tables = Set(graph.nodes.map(\.tableName))
        return graph.edges
            .filter { tables.contains($0.fromTable) && tables.contains($0.toTable) }
            .sorted { lhs, rhs in
                (lhs.fromTable, lhs.toTable, lhs.fromColumn, lhs.toColumn, lhs.fkName)
                    < (rhs.fromTable, rhs.toTable, rhs.fromColumn, rhs.toColumn, rhs.fkName)
            }
    }
}
