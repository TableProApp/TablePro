//
//  MainContentCoordinator+LiveMessages.swift
//  TablePro
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit

extension MainContentCoordinator {
    // Answers without I/O, so a menu validation can ask. The subscription itself runs on connections of its own.
    private var liveMessaging: (any PluginDatabaseDriver & PluginLiveMessaging)? {
        guard AppModuleSettings.shared.isEnabled(.liveMessages),
              connection.type.supportsConnectionPooling,
              let adapter = services.databaseManager.driver(for: connectionId) as? PluginDriverAdapter,
              let messaging = adapter.schemaPluginDriver as? any PluginDatabaseDriver & PluginLiveMessaging,
              messaging.liveMessageKind != nil
        else { return nil }
        return messaging
    }

    func canOpenLiveMessages() -> Bool {
        liveMessaging != nil && services.databaseManager.session(for: connectionId)?.isConnected == true
    }

    func openLiveMessages() {
        guard let kind = liveMessaging?.liveMessageKind, let window = contentWindow else { return }
        let suggested = kind == .topics ? tabManager.selectedTab?.tableContext.tableName : nil
        let setup = RoutineDebugSetup()
        Task {
            let request = await RoutineDebugSheet.present(on: window, setup: setup) { finish in
                LiveMessageStartSheet(kind: kind, suggestedChannel: suggested ?? "", onFinish: finish)
            }
            guard let request else { return }
            openLiveMessageTab(kind: kind, request: request)
        }
    }

    // Not a user close: nothing goes to Reopen Closed Tab and the saved tab set is left alone.
    func closeLiveMessageTabs() {
        let ids = tabManager.tabs.filter { $0.tabType == .liveMessages }.map(\.id)
        for id in ids where tabManager.tabs.contains(where: { $0.id == id }) {
            tabManager.closeTab(id: id)
        }
    }

    private func openLiveMessageTab(kind: PluginLiveMessageKind, request: PluginLiveSubscriptionRequest) {
        // Read again: the module may have gone off, or the connection dropped, while the sheet was up.
        guard let messaging = liveMessaging, let scope = browseScope else { return }
        let controller = LiveMessageController(
            kind: kind,
            request: request,
            makeSource: { LiveMessageSessionSource.live(scope: scope) },
            subscribe: { source in try await messaging.subscribe(request, sessions: source) }
        )
        let tabId = UUID()
        LiveMessageSessions.shared.register(controller, tabId: tabId)
        tabManager.addLiveMessagesTab(id: tabId, title: LiveMessageController.title(for: request))
        controller.start()
    }
}
