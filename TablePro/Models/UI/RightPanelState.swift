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
    /// The connection this panel's session talks to, held so the view model has it from creation.
    /// It used to arrive from `AIChatPanelView.onAppear`, which meant a send before the panel's
    /// first layout ran with no connection and skipped every policy and Safe Mode check.
    @ObservationIgnored private var connection: DatabaseConnection?
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

    @ObservationIgnored private let registry: AgentSessionRegistry

    /// This connection's session, or nil when it has none. A read, never a create: this is what
    /// SwiftUI bodies and `MainContentView` call on every connection window, and the creating getter
    /// that used to live here minted a session for a connection nobody had opened a chat on while
    /// mutating observed state during a view update.
    var session: AgentSession? {
        guard let connectionId else { return nil }
        return registry.existingDefaultSession(for: connectionId)
    }

    var aiViewModel: AIChatViewModel? { session?.viewModel }

    /// The create. Every caller is a user action or an explicit `.task`: choosing the inspector's AI
    /// tab, switching the window to Assistant mode, sending a prompt from Welcome, or asking the
    /// editor to explain a statement. Nil only when the panel has no connection record yet, and a
    /// session with no connection is exactly what phase 2 made impossible.
    @discardableResult
    func startSession() -> AgentSession? {
        guard let connection else { return nil }
        return registry.session(for: connection)
    }

    init(
        connectionId: UUID? = nil,
        connection: DatabaseConnection? = nil,
        defaults: UserDefaults = .standard,
        registry: AgentSessionRegistry = .shared
    ) {
        self.connectionId = connectionId
        self.connection = connection
        self.defaults = defaults
        self.registry = registry
        if let connectionId,
           let raw = defaults.string(forKey: Self.activeTabKey(connectionId)),
           let tab = RightPanelTab(rawValue: raw) {
            self.activeTab = tab
        } else {
            self.activeTab = .details
        }
    }

    /// Pushed in when the stored connection record changes, so the session's copy does not go stale.
    /// Only the record for this panel's own connection is taken: a bulk update names every record,
    /// and adopting another connection's would repoint the session's authorization checks at it.
    ///
    /// Every session on the connection is updated, not just the one the panel resolves to, because a
    /// second session on the same connection runs its Safe Mode checks against its own copy.
    internal func refreshConnectionRecord(_ record: DatabaseConnection) {
        guard record.id == connectionId else { return }
        connection = record
        for owned in registry.sessions(for: record.id) {
            owned.connectionName = record.name
            owned.viewModel.connection = record
        }
    }

    private static func activeTabKey(_ connectionId: UUID) -> String {
        "com.TablePro.rightPanel.activeTab.\(connectionId.uuidString)"
    }

    /// Release all heavy data on disconnect so memory drops
    /// even if AppKit keeps the window alive.
    ///
    /// The session is stopped, not cleared. `clearSessionData()` used to run here, which emptied
    /// `messages` on a path the user never asked to lose a transcript on: window close, workspace
    /// teardown and session loss all reach here. Stopping cancels the stream, persists the partial
    /// turn and marks the session so the rail can still list it and reopen it.
    func teardown() {
        guard !_didTeardown.withLock({ $0 }) else { return }
        _didTeardown.withLock { $0 = true }
        onSave = nil
        if let connectionId {
            registry.stopSessions(for: connectionId)
        }
        jsonViewModel.releaseData()
        editState.releaseData()
    }
}
