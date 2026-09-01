//
//  JSONRowInspectorViewModel.swift
//  TablePro
//
//  Expansion, filtering and foreign key fetching for the JSON inspector.
//

import AppKit
import Foundation
import os

@MainActor
@Observable
final class JSONRowInspectorViewModel {
    private(set) var root: JSONRowNode?
    private(set) var states = JSONForeignKeyStates()
    /// Session state, not a setting. Following a key costs a query per key, so the tab opens with
    /// them closed however the reader left it last time, and turning it on is a deliberate act.
    private(set) var alwaysExpandForeignKeys = false

    var filterText: String = ""

    private var expanded: Set<JSONNodePath> = []
    private var chains: [JSONNodePath: [JSONForeignKeyVisit]] = [:]
    private var fetches: [JSONNodePath: Task<Void, Never>] = [:]
    private var snapshotIdentity: String?
    private var contentToken: Int?
    private var connectionId: UUID?
    private var databaseType: DatabaseType?

    private static let logger = Logger(subsystem: "com.TablePro", category: "JSONRowInspector")

    // MARK: - Lifecycle

    /// Drops the tree and every fetched row on disconnect, the way the chat and the edit state do.
    func releaseData() {
        reset()
        filterText = ""
        alwaysExpandForeignKeys = false
    }

    // MARK: - Input

    func update(snapshot: JSONRowSnapshot?) {
        guard let snapshot else {
            reset()
            return
        }
        connectionId = snapshot.connectionId
        databaseType = snapshot.databaseType

        let isSameRow = snapshot.rowIdentity == snapshotIdentity
        guard !isSameRow || snapshot.contentToken != contentToken else { return }

        if !isSameRow {
            cancelFetches()
            states = JSONForeignKeyStates()
            chains = [:]
        }
        snapshotIdentity = snapshot.rowIdentity
        contentToken = snapshot.contentToken

        let rebuilt = JSONRowNodeBuilder.build(
            columns: snapshot.columns,
            values: snapshot.values,
            columnTypes: snapshot.columnTypes,
            foreignKeys: snapshot.foreignKeys
        )
        root = rebuilt
        if isSameRow {
            expanded.insert(rebuilt.path)
        } else {
            expanded = [rebuilt.path]
            expandContainers(in: rebuilt)
        }

        guard alwaysExpandForeignKeys else { return }
        autoExpandForeignKeys(in: rebuilt)
    }

    private func reset() {
        cancelFetches()
        snapshotIdentity = nil
        contentToken = nil
        root = nil
        expanded = []
        chains = [:]
        states = JSONForeignKeyStates()
    }

    /// An embedded JSON document arrives expanded, the way the grid's own JSON preview shows it.
    /// Only foreign keys cost a round trip, so only they start closed.
    private func expandContainers(in node: JSONRowNode) {
        for child in node.children where child.isContainer {
            expanded.insert(child.path)
            expandContainers(in: child)
        }
    }

    // MARK: - Display

    var displayRows: [JSONDisplayRow] {
        guard let root else { return [] }
        switch JSONRowMatcher.make(query: filterText) {
        case .empty, .invalidRegex:
            return JSONRowFlattener.rows(root: root, expanded: expanded, states: states)
        case .matcher(let matcher):
            let visible = JSONRowFilter.visiblePaths(
                root: root,
                fetchedForeignKeys: states.fetched,
                matcher: matcher
            )
            return JSONRowFlattener.rows(
                root: root,
                expanded: expanded,
                states: states,
                visiblePaths: visible
            )
        }
    }

    var isFilterInvalid: Bool {
        if case .invalidRegex = JSONRowMatcher.make(query: filterText) { return true }
        return false
    }

    var isFiltering: Bool {
        if case .matcher = JSONRowMatcher.make(query: filterText) { return true }
        return false
    }

    // MARK: - Expansion

    func toggle(row: JSONDisplayRow) {
        guard let root else { return }
        if row.foreignKey != nil, states.fetched[row.path] == nil {
            expandForeignKey(at: row.path, in: root)
            return
        }
        if expanded.contains(row.path) {
            expanded.remove(row.path)
        } else {
            expanded.insert(row.path)
        }
    }

    /// Expands what is already in hand. A foreign key that has not been fetched is left alone:
    /// walking every key in a wide row would fire one query per column on a single click.
    func expandAll() {
        guard let root else { return }
        expanded = JSONRowFlattener.expandablePaths(root: root, states: states)
    }

    func collapseAll() {
        expanded = []
    }

    // MARK: - Preferences

    func setAlwaysExpandForeignKeys(_ expand: Bool) {
        alwaysExpandForeignKeys = expand
        guard expand, let root else { return }
        autoExpandForeignKeys(in: root)
    }

    // MARK: - Clipboard

    func copyVisible() {
        let text = JSONRowTextRenderer.render(rows: displayRows)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Foreign Keys

    private func autoExpandForeignKeys(in root: JSONRowNode) {
        for child in root.children where child.foreignKey != nil {
            guard states.fetched[child.path] == nil, fetches[child.path] == nil else { continue }
            expandForeignKey(at: child.path, in: root)
        }
    }

    private func expandForeignKey(at path: JSONNodePath, in root: JSONRowNode) {
        guard fetches[path] == nil,
              let connectionId,
              let databaseType,
              let node = node(at: path, from: root),
              let reference = node.foreignKey,
              let scalar = node.scalar else { return }

        if case .null = scalar { return }
        startFetch(
            path: path,
            reference: reference,
            value: JSONScalarText.unquoted(scalar),
            connectionId: connectionId,
            databaseType: databaseType
        )
    }

    private func startFetch(
        path: JSONNodePath,
        reference: JSONForeignKeyRef,
        value: String,
        connectionId: UUID,
        databaseType: DatabaseType
    ) {
        let visit = JSONForeignKeyVisit(ref: reference, value: value)
        let chain = chain(endingAt: path)

        switch JSONForeignKeyExpansionPolicy.decide(chain: chain, next: visit) {
        case .cycle:
            states.failures[path] = .cycle
            return
        case .depthLimit:
            states.failures[path] = .depthLimit
            return
        case .allowed:
            break
        }

        states.failures.removeValue(forKey: path)
        states.loading.insert(path)

        let identity = snapshotIdentity
        fetches[path] = Task { [weak self] in
            defer { self?.finishFetch(at: path, identity: identity) }
            do {
                let fetched = try await ForeignKeyRowFetcher.fetch(
                    connectionId: connectionId,
                    databaseType: databaseType,
                    reference: reference,
                    value: value,
                    includeForeignKeys: true
                )
                guard let self, !Task.isCancelled, identity == self.snapshotIdentity else { return }
                guard let fetched else {
                    self.states.failures[path] = .notFound
                    return
                }
                self.adopt(fetched: fetched, at: path, reference: reference, chain: chain + [visit])
            } catch {
                Self.logger.error("Foreign key expansion failed: \(error.localizedDescription)")
                guard let self, !Task.isCancelled, identity == self.snapshotIdentity else { return }
                self.states.failures[path] = .failed(String(localized: "Failed to load referenced row"))
            }
        }
    }

    private func adopt(
        fetched: ForeignKeyRowFetcher.FetchedRow,
        at path: JSONNodePath,
        reference: JSONForeignKeyRef,
        chain: [JSONForeignKeyVisit]
    ) {
        let expansion = JSONRowNodeBuilder.build(
            path: path,
            key: .name(reference.column),
            columns: fetched.columns,
            values: fetched.values,
            columnTypes: fetched.columnTypes,
            foreignKeys: fetched.foreignKeys
        )
        states.fetched[path] = expansion
        chains[path] = chain
        expanded.insert(path)
        expandContainers(in: expansion)
    }

    private func finishFetch(at path: JSONNodePath, identity: String?) {
        fetches.removeValue(forKey: path)
        guard identity == snapshotIdentity else { return }
        states.loading.remove(path)
    }

    private func cancelFetches() {
        for task in fetches.values { task.cancel() }
        fetches = [:]
    }

    /// The keys already followed to reach `path`, nearest ancestor first, which is what the cycle
    /// check needs: the chain lives on the expansion that produced the subtree, not on the node.
    private func chain(endingAt path: JSONNodePath) -> [JSONForeignKeyVisit] {
        var components = path.components
        while !components.isEmpty {
            components.removeLast()
            if let chain = chains[JSONNodePath(components: components)] { return chain }
        }
        return []
    }

    private func node(at path: JSONNodePath, from root: JSONRowNode) -> JSONRowNode? {
        if path == root.path { return root }
        for child in JSONRowFilter.children(of: root, fetched: states.fetched) {
            if path.components.count >= child.path.components.count,
               Array(path.components.prefix(child.path.components.count)) == child.path.components,
               let found = node(at: path, from: child) {
                return found
            }
        }
        return nil
    }
}
