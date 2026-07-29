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
    @ObservationIgnored private let connectionId: UUID?
    @ObservationIgnored private let defaults: UserDefaults

    var activeTab: RightPanelTab {
        didSet {
            guard let connectionId else { return }
            defaults.set(activeTab.rawValue, forKey: Self.activeTabKey(connectionId))
        }
    }

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

    init(connectionId: UUID? = nil, defaults: UserDefaults = .standard) {
        self.connectionId = connectionId
        self.defaults = defaults
        if let connectionId,
           let raw = defaults.string(forKey: Self.activeTabKey(connectionId)),
           let tab = RightPanelTab(rawValue: raw) {
            self.activeTab = tab
        } else {
            self.activeTab = .details
        }
    }

    private static func activeTabKey(_ connectionId: UUID) -> String {
        "com.TablePro.rightPanel.activeTab.\(connectionId.uuidString)"
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
