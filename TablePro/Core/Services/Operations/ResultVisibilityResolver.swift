//
//  ResultVisibilityResolver.swift
//  TablePro
//

import AppKit
import Foundation

/// Reads the live window state behind `ResultVisibility`.
///
/// Two rules this must not lose. `NSWindow.occlusionState` is an option set whose live value
/// carries an undocumented high bit (measured on macOS 27: 8194 visible, 8192 occluded) while
/// `.visible` is 1 << 1, so `occlusionState == .visible` is always false and inverts the whole
/// gate. Membership is the only correct test, and it already goes false for a miniaturized window
/// and for a hidden app, so neither needs a separate check.
///
/// Sampling is direct rather than cached off `didChangeOcclusionStateNotification`. The state
/// settles about one runloop after the event, but the sample point here is an operation
/// finishing, which is not synchronous with a visibility change, and the race is milliseconds
/// against an operation that ran for at least the notification threshold.
@MainActor
internal enum ResultVisibilityResolver {
    internal static func resolve(owner: OperationOwner, connectionId: UUID) -> ResultVisibility {
        let appIsActive = NSApp.isActive

        guard case .tab(let windowId, let tabId) = owner else {
            let windows = WindowLifecycleMonitor.shared.windows(for: connectionId)
            return ResultVisibility(
                appIsActive: appIsActive,
                ownerWindowIsVisible: windows.contains(where: isVisible),
                ownerIsSelectedInWindow: true
            )
        }

        guard let window = resolveWindow(windowId: windowId, connectionId: connectionId) else {
            return ResultVisibility(
                appIsActive: appIsActive,
                ownerWindowIsVisible: false,
                ownerIsSelectedInWindow: false
            )
        }

        return ResultVisibility(
            appIsActive: appIsActive,
            ownerWindowIsVisible: isVisible(window),
            ownerIsSelectedInWindow: selectedTabId(in: window) == tabId
        )
    }

    private static func resolveWindow(windowId: UUID?, connectionId: UUID) -> NSWindow? {
        guard let windowId else { return WindowLifecycleMonitor.shared.mostRecentWindow(for: connectionId) }
        return WindowLifecycleMonitor.shared.window(for: windowId)
    }

    private static func isVisible(_ window: NSWindow) -> Bool {
        window.occlusionState.contains(.visible)
    }

    private static func selectedTabId(in window: NSWindow) -> UUID? {
        guard let controller = window.contentViewController as? MainSplitViewController else { return nil }
        return controller.workspaces.selected?.sessionState?.tabManager.selectedTab?.id
    }
}
