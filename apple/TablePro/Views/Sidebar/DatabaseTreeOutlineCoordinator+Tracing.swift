//
//  DatabaseTreeOutlineCoordinator+Tracing.swift
//  TablePro
//

import AppKit

// The sidebar's interaction traces end on the first reload that shows their answer with nothing left loading.
extension DatabaseTreeOutlineCoordinator {
    private var traceKey: String {
        connectionId.uuidString
    }

    internal func beginExpansionTrace(for node: DatabaseTreeNode) {
        guard !isApplyingExpansion else { return }
        switch node.kind {
        case .database, .schema, .hierarchicalSchemaSection:
            InteractionTracer.shared.begin(.sidebarExpand, key: traceKey, subject: node.id)
        default:
            return
        }
    }

    internal func endSettledInteractionTraces() {
        let tracer = InteractionTracer.shared
        guard tracer.isRecording, let outlineView, let window = outlineView.window else { return }
        let key = traceKey
        let awaitsListing = tracer.subject(of: .sidebarListing, key: key) != nil
        let filter = tracer.subject(of: .sidebarFilter, key: key)
        let expanding = tracer.subject(of: .sidebarExpand, key: key)
        guard awaitsListing || filter != nil || expanding != nil,
              let rows = settledRowCount(in: outlineView)
        else { return }
        if awaitsListing, rows > 0, isCatalogSettled {
            tracer.end(.sidebarListing, key: key, detail: "rows=\(rows)", after: window)
        }
        if let filter, filter == searchText, let listing = searchListingOutcome(for: filter) {
            tracer.end(
                .sidebarFilter, key: key, detail: "chars=\(filter.count) rows=\(rows) listing=\(listing)", after: window
            )
        }
        if let expanding, let node = nodeCache[expanding], outlineView.isItemExpanded(node) {
            tracer.end(.sidebarExpand, key: key, detail: "rows=\(rows)", after: window)
        }
    }

    private var isCatalogSettled: Bool {
        switch schemaService.state(for: connectionId) {
        case .loaded, .failed: return true
        case .idle, .loading: return false
        }
    }

    // Other schemas' matches join a search once the all-schema listings land, and the requests for them
    // start a turn after the search does, so an idle listing is still on its way. Nil until they settle.
    private func searchListingOutcome(for filter: String) -> String? {
        guard !filter.isEmpty else { return "none" }
        let databases = searchListingDatabases
        guard !databases.isEmpty else { return "none" }
        var failed = false
        for database in databases {
            switch service.allSchemaTablesLoadState(connectionId: connectionId, database: database) {
            case .loaded: continue
            case .failed: failed = true
            case .idle, .loading: return nil
            }
        }
        return failed ? "failed" : "loaded"
    }

    // Nil while any open row still reads Loading. A Loading row is always its parent's only child, so the
    // children built so far answer this without walking tens of thousands of rows.
    private func settledRowCount(in outlineView: NSOutlineView) -> Int? {
        for (parentId, children) in childrenCache {
            guard children.count == 1, case .status(.loading) = children[0].kind else { continue }
            guard !parentId.isEmpty else { return nil }
            if let parent = nodeCache[parentId], outlineView.row(forItem: parent) >= 0, outlineView.isItemExpanded(parent) {
                return nil
            }
        }
        return outlineView.numberOfRows
    }
}
