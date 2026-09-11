//
//  WorkspaceContentModeStore.swift
//  TablePro
//

import Foundation

/// Which content mode each connection was last left in, so a relaunch reopens the surface the
/// user chose rather than always the object browser.
///
/// Keyed by connection alone, not by window plus connection. A connection is hosted by exactly one
/// window at a time: `WindowManager.openTab` routes an open to the window already hosting it, the
/// registry dedups by connection id, and `moveToNewWindow` removes the workspace from its old host
/// before inserting it into the new one. So two hosts never hold one connection, and there is no
/// second writer to race with. This is the same shape as every other per-connection store.
@MainActor
internal final class WorkspaceContentModeStore {
    internal static let shared = WorkspaceContentModeStore()

    private let defaults: UserDefaults

    internal init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(connectionId: UUID) -> String {
        "com.TablePro.workspaceContentMode.\(connectionId.uuidString)"
    }

    /// An unrecognised stored string falls back to `.browse` rather than being treated as a
    /// missing value, because a mode written by a newer release must never leave the window with
    /// no content at all.
    internal func mode(connectionId: UUID) -> ConnectionWorkspaceContentMode {
        guard let raw = defaults.string(forKey: key(connectionId: connectionId)),
              let mode = ConnectionWorkspaceContentMode(rawValue: raw)
        else { return .browse }
        return mode
    }

    internal func setMode(_ mode: ConnectionWorkspaceContentMode, connectionId: UUID) {
        let storageKey = key(connectionId: connectionId)
        guard mode != .browse else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        defaults.set(mode.rawValue, forKey: storageKey)
    }

    internal func removeMode(for connectionId: UUID) {
        defaults.removeObject(forKey: key(connectionId: connectionId))
    }
}
