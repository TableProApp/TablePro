//
//  ZoomCommandResponding.swift
//  TablePro
//

import AppKit

// View > Zoom In and Zoom Out go to whatever is nearest the focus: a diagram's scroll view, a data
// grid's scroll view, then the window, which zooms the editor. One item per verb, because two items
// sharing Command-= resolve by menu order rather than by focus.
@MainActor
@objc protocol ZoomCommandResponding {
    func zoomIn(_ sender: Any?)
    func zoomOut(_ sender: Any?)
}

// A pane whose zoom is its font size in Settings, so a zoom is the same edit the size picker makes.
enum FontSizeZoom {
    case editor
    case dataGrid

    // Nil for any other command. Read live: the size is the app's setting, not one window's.
    func enablement(_ action: Selector, typography: TypographySettings) -> Bool? {
        switch action {
        case #selector(ZoomCommandResponding.zoomIn(_:)):
            return size(in: typography, zoomedBy: 1) != nil
        case #selector(ZoomCommandResponding.zoomOut(_:)):
            return size(in: typography, zoomedBy: -1) != nil
        default:
            return nil
        }
    }

    @MainActor
    func zoom(by delta: Int, settings: AppSettingsManager = .shared) {
        var typography = settings.typography
        guard let size = size(in: typography, zoomedBy: delta) else { return }
        switch self {
        case .editor:
            typography.editorFontSize = size
        case .dataGrid:
            typography.dataGridFontSize = size
        }
        settings.typography = typography
    }

    private func size(in typography: TypographySettings, zoomedBy delta: Int) -> Int? {
        switch self {
        case .editor:
            return typography.editorFontSize(zoomedBy: delta)
        case .dataGrid:
            return typography.dataGridFontSize(zoomedBy: delta)
        }
    }
}
