//
//  DatabaseTreeNodeCache.swift
//  TablePro
//

import Foundation

// One object per row id, so AppKit keeps a row's disclosure and selection across rebuilds.
struct DatabaseTreeNodeCache: ExpressibleByDictionaryLiteral {
    private var nodes: [String: DatabaseTreeNode]
    // Nil once a row came or went. The selection is what reads it, and that changes far less often than rows do.
    private var tableIndex: [TableInfo: [DatabaseTreeNode]]?

    init(dictionaryLiteral elements: (String, DatabaseTreeNode)...) {
        nodes = Dictionary(elements) { _, last in last }
    }

    subscript(id: String) -> DatabaseTreeNode? {
        get { nodes[id] }
        set {
            nodes[id] = newValue
            tableIndex = nil
        }
    }

    var values: Dictionary<String, DatabaseTreeNode>.Values {
        nodes.values
    }

    var count: Int {
        nodes.count
    }

    mutating func nodes(drawing tables: Set<TableInfo>) -> [DatabaseTreeNode] {
        let index = tableIndex ?? makeTableIndex()
        tableIndex = index
        return tables.flatMap { index[$0] ?? [] }
    }

    mutating func invalidateTableIndex() {
        tableIndex = nil
    }

    mutating func removeNodes(where shouldRemove: (DatabaseTreeNode) -> Bool) {
        let before = nodes.count
        nodes = nodes.filter { !shouldRemove($0.value) }
        if nodes.count != before { tableIndex = nil }
    }

    private func makeTableIndex() -> [TableInfo: [DatabaseTreeNode]] {
        var index: [TableInfo: [DatabaseTreeNode]] = [:]
        for node in nodes.values {
            guard let table = node.tableRef?.table else { continue }
            index[table, default: []].append(node)
        }
        return index
    }
}
