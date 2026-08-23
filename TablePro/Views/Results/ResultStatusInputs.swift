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
    let all: [String]
    let onToggle: (String) -> Void
    let onShowAll: () -> Void
    let onHideAll: ([String]) -> Void
    let onReset: () -> Void
}
