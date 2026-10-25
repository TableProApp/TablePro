//
//  DataGridHeaderView.swift
//  TablePro
//

import AppKit

// The menu is resolved from the event, and drawn cells need a repaint on each step of a column drag.
@MainActor
final class DataGridHeaderView: ThemeTableHeaderView {
    var paneKind: DataGridPane.Kind = .main
    private var bodyFollowsColumnDrag = false

    private var controller: DataGridViewController? {
        (tableView as? DataGridTableView)?.controller
    }

    override var themeScope: ThemeScope {
        controller?.model.themeScope ?? .live
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tableView else { return nil }
        let index = column(at: convert(event.locationInWindow, from: nil))
        guard index >= 0, index < tableView.tableColumns.count else { return nil }
        return controller?.headerMenu(forTableColumn: tableView.tableColumns[index], in: paneKind)
    }

    // AppKit redraws the header on every step of a resize or reorder drag but posts the column notifications only at mouse-up.
    override func viewWillDraw() {
        super.viewWillDraw()
        let isDragging = resizedColumn >= 0 || draggedColumn >= 0
        guard isDragging || bodyFollowsColumnDrag else { return }
        bodyFollowsColumnDrag = isDragging
        controller?.headerGeometryDidStep(in: paneKind)
    }
}
