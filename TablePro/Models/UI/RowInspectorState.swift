//
//  RowInspectorState.swift
//  TablePro
//

import Foundation

/// The inspector surface's own state: which rendering of the row is showing, what the row is, and
/// the two models that draw it.
@MainActor @Observable internal final class RowInspectorState {
    @ObservationIgnored private let connectionId: UUID?
    @ObservationIgnored private let defaults: UserDefaults

    internal var viewMode: InspectorViewMode {
        didSet {
            guard let connectionId else { return }
            defaults.set(viewMode.rawValue, forKey: Self.viewModeKey(connectionId))
        }
    }

    /// The JSON model is fed here rather than from the JSON view's own `onChange`.
    ///
    /// A view's `onChange` runs after the render that already observed the new value, so the view
    /// drew one frame of the previous record's tree before the model caught up and moving between
    /// rows flickered. Writing both in the same turn means every render sees one consistent row.
    internal var context: RowInspectorContext = .empty {
        didSet {
            guard context != oldValue else { return }
            jsonViewModel.update(snapshot: context.jsonRow)
        }
    }

    /// Still genuinely multi-row: a selection of several rows edits one field across all of them,
    /// and each field reports whether they disagree.
    internal let editState = MultiRowEditState()

    /// Held here rather than as the JSON view's own `@State` so switching to fields and back keeps
    /// the reader's expansions and the rows already fetched for them.
    internal let jsonViewModel = JSONRowInspectorViewModel()

    internal init(connectionId: UUID? = nil, defaults: UserDefaults = .standard) {
        self.connectionId = connectionId
        self.defaults = defaults
        if let connectionId,
           let raw = defaults.string(forKey: Self.viewModeKey(connectionId)),
           let mode = InspectorViewMode(rawValue: raw) {
            self.viewMode = mode
        } else {
            self.viewMode = .fields
        }
    }

    internal func teardown() {
        jsonViewModel.releaseData()
        editState.releaseData()
        context = .empty
    }

    internal static func viewModeKey(_ connectionId: UUID) -> String {
        "com.TablePro.inspector.viewMode.\(connectionId.uuidString)"
    }
}
