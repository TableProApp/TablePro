//
//  OperationCompletionReporter+Handling.swift
//  TablePro
//

import AppKit
import Foundation
import UserNotifications

extension OperationCompletionReporter: NotificationHandling {
    /// Re-runs the visibility rule rather than testing `NSApp.isActive`.
    ///
    /// This callback only fires while TablePro is in the foreground; when it is in the background
    /// the system presents the notification without asking. So `NSApp.isActive` is true on every
    /// call here, and suppressing on it would silence exactly the case the feature exists for:
    /// work that finished on a tab the user had switched away from, in an app they are still
    /// using. The result being on screen right now is the only reason to withhold the banner, and
    /// it is a live question because the user can select that tab between the policy deciding and
    /// the notification arriving.
    internal func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions {
        guard let payload = OperationNotificationPayload(userInfo: notification.request.content.userInfo),
              let connectionId = payload.connectionId
        else { return [.banner, .list] }

        let owner: OperationOwner = payload.tabId.map {
            .tab(windowId: payload.windowId, tabId: $0)
        } ?? .connection(connectionId)

        let visibility = ResultVisibilityResolver.resolve(owner: owner, connectionId: connectionId)
        return visibility.resultIsOnScreen ? [] : [.banner, .list]
    }

    internal func handle(_ response: UNNotificationResponse) {
        guard let payload = OperationNotificationPayload(userInfo: response.notification.request.content.userInfo)
        else { return }

        switch response.actionIdentifier {
        case OperationCompletionPolicy.copyErrorActionId:
            guard let reason = payload.failureReason else { return }
            ClipboardService.shared.writeText(reason)

        case OperationCompletionPolicy.revealFileActionId:
            /// The payload round-trips through the system's notification store as a plain string,
            /// so the scheme is re-checked rather than assumed. Only an export or a backup ever
            /// sets this, and both write a file.
            guard let url = payload.revealURL, url.isFileURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])

        case UNNotificationDefaultActionIdentifier:
            focusOwner(payload)

        default:
            return
        }
    }

    private func focusOwner(_ payload: OperationNotificationPayload) {
        NSApp.activate(ignoringOtherApps: true)

        guard let window = ownerWindow(payload) else { return }
        window.makeKeyAndOrderFront(nil)

        guard let controller = window.contentViewController as? MainSplitViewController else { return }

        if let connectionId = payload.connectionId, controller.hostedConnectionIds.contains(connectionId) {
            controller.selectHostedConnection(connectionId)
        }

        guard let tabId = payload.tabId, let coordinator = coordinator(in: controller, for: payload.connectionId)
        else { return }

        /// A tab retargeted or closed while its work ran is gone, and the notification said so by
        /// carrying the outcome without a target. Selecting a stale id here would focus whatever
        /// tab happens to sit in that position now.
        guard coordinator.tabManager.tabs.contains(where: { $0.id == tabId }) else { return }
        coordinator.selectTabAndFocusWindow(tabId)
    }

    private func coordinator(
        in controller: MainSplitViewController,
        for connectionId: UUID?
    ) -> MainContentCoordinator? {
        guard let connectionId else { return controller.workspaces.selected?.sessionState?.coordinator }
        return controller.workspaces.workspace(for: connectionId)?.sessionState?.coordinator
    }

    private func ownerWindow(_ payload: OperationNotificationPayload) -> NSWindow? {
        if let windowId = payload.windowId, let window = WindowLifecycleMonitor.shared.window(for: windowId) {
            return window
        }
        guard let connectionId = payload.connectionId else { return nil }
        return WindowLifecycleMonitor.shared.mostRecentWindow(for: connectionId)
    }
}
