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

struct HighlightPresentationRequest: Equatable {
    let tabId: UUID?
    let count: Int
}

struct StatusBarHighlightState {
    let rules: [HighlightRule]
    let columns: [String]
    let isPersisted: Bool
    let presentationRequest: Int
    let onChange: ([HighlightRule]) -> Void
    let onDismiss: (UUID) -> Void

    var activeRuleCount: Int {
        rules.filter { $0.isEnabled && $0.isValid && !$0.hasUnusablePattern }.count
    }
}

struct StatusBarAutoRefreshState {
    let interval: TableAutoRefreshInterval
    let pause: TableAutoRefreshPause?
    let onChange: (TableAutoRefreshInterval) -> Void

    static var unavailable: StatusBarAutoRefreshState {
        StatusBarAutoRefreshState(interval: .off, pause: nil, onChange: { _ in })
    }

    var help: String {
        if interval.isOn, let reason = pause?.help { return reason }
        return String(format: String(localized: "Auto Refresh: %@"), interval.title)
    }
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
