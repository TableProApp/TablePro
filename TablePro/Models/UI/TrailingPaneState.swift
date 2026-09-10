//
//  TrailingPaneState.swift
//  TablePro
//

import Foundation
import os

/// One connection's trailing pane: which surface it shows, and the two surfaces' own state.
///
/// This is the owner, not a third concern. The inspector knows nothing about the assistant and the
/// assistant nothing about the row, which is the whole point of the split; something still has to
/// say which of them the pane is currently drawing and to persist that per connection.
@MainActor @Observable internal final class TrailingPaneState {
    @ObservationIgnored private let _didTeardown = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored private let connectionId: UUID?
    @ObservationIgnored private let defaults: UserDefaults

    /// Which surface the pane draws when it is revealed. Revealing is a separate question, owned by
    /// the split view controller: the pane can be collapsed with a surface still remembered here,
    /// which is what lets a reveal put back what the user was last looking at.
    internal var surface: TrailingPaneSurface {
        didSet {
            guard let connectionId else { return }
            defaults.set(surface.rawValue, forKey: Self.surfaceKey(connectionId))
        }
    }

    internal let inspector: RowInspectorState
    internal let assistant = AssistantState()

    internal init(connectionId: UUID? = nil, defaults: UserDefaults = .standard) {
        self.connectionId = connectionId
        self.defaults = defaults
        /// Before anything reads the keys it writes. `RowInspectorState` takes its view mode in its
        /// own initializer, so building it first leaves it holding the default while the migration
        /// writes the real value underneath it.
        if let connectionId {
            Self.migrateLegacyTabIfNeeded(connectionId: connectionId, defaults: defaults)
        }
        self.inspector = RowInspectorState(connectionId: connectionId, defaults: defaults)
        if let connectionId,
           let raw = defaults.string(forKey: Self.surfaceKey(connectionId)),
           let stored = TrailingPaneSurface(rawValue: raw) {
            self.surface = stored
        } else {
            self.surface = .inspector
        }
    }

    /// Releases everything heavy on disconnect so memory drops even when AppKit keeps the window.
    internal func teardown() {
        guard !_didTeardown.withLock({ $0 }) else { return }
        _didTeardown.withLock { $0 = true }
        inspector.teardown()
        assistant.teardown()
    }

    internal static func surfaceKey(_ connectionId: UUID) -> String {
        "com.TablePro.trailingPane.surface.\(connectionId.uuidString)"
    }

    internal static let legacyActiveTabKeyPrefix = "com.TablePro.rightPanel.activeTab."

    /// Carries a connection forward from the single three-way tab the pane used to persist.
    ///
    /// The old key stored one of "Details", "JSON" or "AI Chat", which conflated the surface with
    /// the inspector's view mode. A user last left on AI Chat gets the assistant surface; one left
    /// on JSON gets the inspector showing JSON. Without this, everyone lands on the inspector's
    /// fields and the surface they were using looks removed rather than moved.
    private static func migrateLegacyTabIfNeeded(connectionId: UUID, defaults: UserDefaults) {
        let legacyKey = legacyActiveTabKeyPrefix + connectionId.uuidString
        guard let legacy = defaults.string(forKey: legacyKey) else { return }
        defaults.removeObject(forKey: legacyKey)

        guard defaults.string(forKey: surfaceKey(connectionId)) == nil else { return }
        switch legacy {
        case "AI Chat":
            defaults.set(TrailingPaneSurface.assistant.rawValue, forKey: surfaceKey(connectionId))
        case "JSON":
            defaults.set(TrailingPaneSurface.inspector.rawValue, forKey: surfaceKey(connectionId))
            defaults.set(InspectorViewMode.json.rawValue, forKey: RowInspectorState.viewModeKey(connectionId))
        default:
            defaults.set(TrailingPaneSurface.inspector.rawValue, forKey: surfaceKey(connectionId))
        }
    }
}
