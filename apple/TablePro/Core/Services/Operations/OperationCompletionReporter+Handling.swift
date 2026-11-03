//
//  OperationCompletionReporter+Handling.swift
//  TablePro
//

import AppKit
import Foundation
import UserNotifications

extension OperationCompletionReporter: NotificationHandling {
    // Only called while the app is frontmost, so the live question is whether the result is on screen now.
    internal func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions {
        guard let payload = OperationNotificationPayload(userInfo: notification.request.content.userInfo),
              let connectionId = payload.connectionId
        else { return [.banner, .list] }

        let owner: OperationOwner = payload.compareWindowId.map { .compareWindow($0) }
            ?? payload.tabId.map { .tab(windowId: payload.windowId, tabId: $0) }
            ?? .connection(connectionId)

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
            // The URL round-trips as a string through the notification store, so the scheme is checked again.
            guard let url = payload.revealURL, url.isFileURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])

        case UNNotificationDefaultActionIdentifier:
            focusOwner(payload)

        default:
            return
        }
    }

    private func focusOwner(_ payload: OperationNotificationPayload) {
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)

        if let compareWindowId = payload.compareWindowId {
            CompareSyncWindowController.window(for: compareWindowId)?.makeKeyAndOrderFront(nil)
            return
        }
        guard let window = ownerWindow(payload) else { return }
        window.makeKeyAndOrderFront(nil)

        guard let controller = window.contentViewController as? MainSplitViewController else { return }

        if let connectionId = payload.connectionId, controller.hostedConnectionIds.contains(connectionId) {
            controller.selectHostedConnection(connectionId)
        }

        guard let tabId = payload.tabId, let coordinator = coordinator(in: controller, for: payload.connectionId)
        else { return }

        // A tab retargeted or closed meanwhile is gone; a stale id would focus whatever sits there now.
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
