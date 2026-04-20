//
//  RightPanelState.swift
//  TablePro
//
//  Per-window state for the right panel: active tab, edit state, AI chat.
//

import Foundation
import os

@MainActor @Observable final class RightPanelState {
    @ObservationIgnored private let _didTeardown = OSAllocatedUnfairLock(initialState: false)

    var activeTab: RightPanelTab = .details
    var inspectorContext: InspectorContext = .empty

    // Save closure — set by MainContentCommandActions, called by UnifiedRightPanelView
    var onSave: (() -> Void)?

    // Owned objects — lifted from MainContentView @StateObject
    let editState = MultiRowEditState()
    private var _aiViewModel: AIChatViewModel?
    var aiViewModel: AIChatViewModel {
        if _aiViewModel == nil {
            _aiViewModel = AIChatViewModel()
        }
        return _aiViewModel! // swiftlint:disable:this force_unwrapping
    }

    /// Release all heavy data on disconnect so memory drops
    /// even if AppKit keeps the window alive.
    func teardown() {
        guard !_didTeardown.withLock({ $0 }) else { return }
        _didTeardown.withLock { $0 = true }
        onSave = nil
        _aiViewModel?.clearSessionData()
        editState.releaseData()
    }
}
