//
//  ResultVisibilityResolver.swift
//  TablePro
//

import AppKit
import Foundation

// occlusionState carries an undocumented high bit (8194 visible on macOS 27), so only membership tests `.visible`.
@MainActor
internal enum ResultVisibilityResolver {
    internal static func resolve(owner: OperationOwner, connectionId: UUID) -> ResultVisibility {
        let appIsActive = NSApp.isActive
        switch owner {
        case .tab(let windowId, let tabId):
            guard let window = resolveWindow(windowId: windowId, connectionId: connectionId) else {
                return ResultVisibility(appIsActive: appIsActive, ownerWindowIsVisible: false, ownerIsSelectedInWindow: false)
            }
            return ResultVisibility(
                appIsActive: appIsActive,
                ownerWindowIsVisible: isVisible(window),
                ownerIsSelectedInWindow: selectedTabId(in: window) == tabId
            )
        case .connection:
            // One window hosts several connections; only a visible window showing this one counts.
            let windows = WindowLifecycleMonitor.shared.windows(for: connectionId).filter(isVisible)
            return ResultVisibility(
                appIsActive: appIsActive,
                ownerWindowIsVisible: !windows.isEmpty,
                ownerIsSelectedInWindow: windows.contains { selectedConnectionId(in: $0) == connectionId }
            )
        case .compareWindow(let id):
            let window = CompareSyncWindowController.window(for: id)
            return ResultVisibility(
                appIsActive: appIsActive,
                ownerWindowIsVisible: window.map(isVisible) ?? false,
                ownerIsSelectedInWindow: window != nil
            )
        }
    }

    private static func resolveWindow(windowId: UUID?, connectionId: UUID) -> NSWindow? {
        guard let windowId else { return WindowLifecycleMonitor.shared.mostRecentWindow(for: connectionId) }
        return WindowLifecycleMonitor.shared.window(for: windowId)
    }

    private static func isVisible(_ window: NSWindow) -> Bool {
        window.occlusionState.contains(.visible)
    }

    private static func selectedConnectionId(in window: NSWindow) -> UUID? {
        guard let controller = window.contentViewController as? MainSplitViewController else { return nil }
        return controller.workspaces.selected?.connectionId
    }

    // Agent mode draws the conversation over the tabs; `showSelectedContentPanes` clears the mark when Browse returns.
    private static func selectedTabId(in window: NSWindow) -> UUID? {
        guard let controller = window.contentViewController as? MainSplitViewController,
              let workspace = controller.workspaces.selected,
              workspace.detailMode == .browse
        else { return nil }
        return workspace.sessionState?.tabManager.selectedTab?.id
    }
}
