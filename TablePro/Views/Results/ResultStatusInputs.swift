//
//  ResultStatusInputs.swift
//  TablePro
//

import Foundation

struct PaginationCallbacks {
    let onFirst: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onLast: () -> Void
    let onPageSizeChange: (Int) -> Void
    let onShowAll: () -> Void
    let onGoToPage: (Int) -> Void
    let onRequestExactCount: () -> Void
}

struct StatusBarColumnState {
    let hidden: Set<String>
    let columns: [GridColumnEntry]
    let onToggle: (String) -> Void
    let onShowAll: () -> Void
    let onHideAll: ([String]) -> Void
    let onReset: () -> Void
    /// Nil where no grid is mounted to jump in, which hides the popover's Jump to Column button.
    let onJumpToColumn: ((String) -> Void)?

    /// What the visibility controls count and toggle: one row per name, because hiding is by name.
    var visibilityColumns: [GridColumnEntry] {
        GridColumnCatalog.uniqueByName(columns)
    }
}
