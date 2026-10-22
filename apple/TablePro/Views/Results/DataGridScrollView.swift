//
//  DataGridScrollView.swift
//  TablePro
//

import AppKit

// Zoom lives here rather than on the table because a cell being edited sits in an overlay mounted on
// this scroll view, so the table is not in that responder chain and this view is in both.
final class DataGridScrollView: NSScrollView, ZoomCommandResponding {
    @objc func zoomIn(_ sender: Any?) {
        FontSizeZoom.dataGrid.zoom(by: 1)
    }

    @objc func zoomOut(_ sender: Any?) {
        FontSizeZoom.dataGrid.zoom(by: -1)
    }
}

extension DataGridScrollView: NSMenuItemValidation {
    // At either end of the range the item dims rather than falling through to the editor's size.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return false }
        return FontSizeZoom.dataGrid.enablement(action, typography: AppSettingsManager.shared.typography) ?? true
    }
}
