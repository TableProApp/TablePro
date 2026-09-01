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

    /// The JSON tab's model is fed here rather than from the tab's own `onChange`.
    ///
    /// A view's `onChange` runs after the render that already observed the new value, so the tab
    /// drew one frame of the previous record's tree before the model caught up: moving between rows
    /// flickered. Writing both in the same turn means every render sees one consistent row.
    var inspectorContext: InspectorContext = .empty {
        didSet {
            jsonViewModel.update(snapshot: inspectorContext.jsonRow)
        }
    }

    // Save closure — set by MainContentCommandActions, called by UnifiedRightPanelView
    var onSave: (() -> Void)?

    // Owned objects — lifted from MainContentView @StateObject
    let editState = MultiRowEditState()

    /// Held here rather than as the JSON tab's own `@State` so a switch to Details and back keeps
    /// the reader's expansions and the rows already fetched for them.
    let jsonViewModel = JSONRowInspectorViewModel()
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
        jsonViewModel.releaseData()
        editState.releaseData()
    }
}
