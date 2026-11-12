//
//  TableAutoRefreshGate.swift
//  TablePro
//

import Foundation

enum TableAutoRefreshPause: Equatable, Sendable {
    case notVisible
    case disconnected
    case otherViewMode
    case openTransaction
    case unsavedChanges
    case editing
    case interacting
    case valueWindowOpen
    case loading
    case safeModePrompt
    case unkeyedSelection

    // Nil where nobody can read the bar's help anyway, or the pause lasts only as long as a gesture.
    var help: String? {
        switch self {
        case .disconnected:
            String(localized: "Auto Refresh waits until the connection is back.")
        case .openTransaction:
            String(localized: "Auto Refresh waits while a transaction is open.")
        case .unsavedChanges:
            String(localized: "Auto Refresh waits while the table has unsaved changes.")
        case .editing:
            String(localized: "Auto Refresh waits while a cell is being edited.")
        case .valueWindowOpen:
            String(localized: "Auto Refresh waits while a value is open in its own window.")
        case .loading:
            String(localized: "Auto Refresh waits while rows load.")
        case .unkeyedSelection:
            String(localized: "Auto Refresh waits while rows are selected in a table without a primary key.")
        case .notVisible, .otherViewMode, .interacting, .safeModePrompt:
            nil
        }
    }
}

enum TableAutoRefreshDecision: Equatable, Sendable {
    case refresh
    case wait(TableAutoRefreshPause)
    case stop
}

struct TableAutoRefreshGate: Equatable, Sendable {
    enum Load: Equatable, Sendable {
        case idle
        case busy
    }

    var isTableTab = true
    var previousTickFailed = false
    var hasLoaded = true
    var windowIsVisible = true
    var isSelectedInWindow = true
    var isConnected = true
    var viewMode: ResultsViewMode = .data
    var holdsTransaction = false
    var holdsUnsavedWork = false
    var hasSidebarDataWork = false
    var isEditingCell = false
    var gridHoldsTransientUI = false
    var gridIsTrackingInteraction = false
    var inspectorHoldsValueWindow = false
    var load: Load = .idle
    var isCountPending = false
    var isLoadingMore = false
    var showsSafeModePrompt = false
    var hasSelection = false
    var hasPrimaryKey = true

    // Never the app being active: watching a jobs table while working in another app is the point.
    var decision: TableAutoRefreshDecision {
        guard isTableTab, !previousTickFailed else { return .stop }
        guard windowIsVisible, isSelectedInWindow else { return .wait(.notVisible) }
        guard isConnected else { return .wait(.disconnected) }
        guard viewMode == .data else { return .wait(.otherViewMode) }
        guard !holdsTransaction else { return .wait(.openTransaction) }
        // Ahead of unsaved work, which counts an open editor too.
        guard !isEditingCell else { return .wait(.editing) }
        guard !holdsUnsavedWork, !hasSidebarDataWork else { return .wait(.unsavedChanges) }
        // A reload closes the grid's viewers and the value filter, and moves rows under a drag or a scroll.
        guard !gridHoldsTransientUI, !gridIsTrackingInteraction else { return .wait(.interacting) }
        guard !inspectorHoldsValueWindow else { return .wait(.valueWindowOpen) }
        guard hasLoaded, load == .idle, !isCountPending, !isLoadingMore else { return .wait(.loading) }
        guard !showsSafeModePrompt else { return .wait(.safeModePrompt) }
        // Rows are kept across a reload by primary key, so without one the selection would be dropped.
        guard !hasSelection || hasPrimaryKey else { return .wait(.unkeyedSelection) }
        return .refresh
    }
}
