//
//  AgentAttentionNotifier.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
import os
import UserNotifications

// Waiting on you and failed need the user even when the session is out of sight; no threshold applies.
@MainActor
internal final class AgentAttentionNotifier {
    internal static let shared = AgentAttentionNotifier()

    internal static let categoryId = "com.TablePro.agentAttention"
    internal static let identifierPrefix = "com.TablePro.agent."
    private static let sessionIdKey = "agentSessionId"
    private static let connectionIdKey = "connectionId"
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "AgentNotifications")

    private let presenter: any UserNotificationPresenting
    private let authorization: NotificationAuthorization
    private let categories: NotificationCategoryRegistry
    private let settings: () -> NotificationSettings
    private let isOnScreen: (AgentSession) -> Bool
    private let connectionName: (UUID) -> String
    private var statusCancellables: [UUID: AnyCancellable] = [:]
    private var sessionsCancellable: AnyCancellable?
    private var delivered: Set<String> = []

    internal init(
        presenter: any UserNotificationPresenting = SystemNotificationPresenter.shared,
        authorization: NotificationAuthorization = .shared,
        categories: NotificationCategoryRegistry = .shared,
        settings: (() -> NotificationSettings)? = nil,
        isOnScreen: ((AgentSession) -> Bool)? = nil,
        connectionName: ((UUID) -> String)? = nil
    ) {
        self.presenter = presenter
        self.authorization = authorization
        self.categories = categories
        self.settings = settings ?? { AppSettingsManager.shared.notifications }
        self.isOnScreen = isOnScreen ?? AgentSessionVisibility.isOnScreen
        self.connectionName = connectionName ?? { connectionId in
            DatabaseManager.shared.session(for: connectionId)?.connection.name
                ?? ConnectionStorage.shared.loadConnection(id: connectionId)?.name
                ?? ""
        }
    }

    internal func setUp(registry: AgentSessionRegistry = .shared) {
        categories.register([UNNotificationCategory(
            identifier: Self.categoryId, actions: [], intentIdentifiers: [], options: []
        )], owner: "agent")
        NotificationRouter.shared.register(self, forCategory: Self.categoryId)
        sessionsCancellable = registry.$sessions.sink { [weak self] sessions in
            self?.observe(sessions)
        }
    }

    internal func observe(_ sessions: [AgentSession]) {
        let ids = Set(sessions.map(\.id))
        for id in statusCancellables.keys where !ids.contains(id) {
            statusCancellables.removeValue(forKey: id)
            withdraw(sessionId: id)
        }
        for session in sessions where statusCancellables[session.id] == nil {
            statusCancellables[session.id] = session.$status
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self, weak session] status in
                    guard let self, let session else { return }
                    self.statusChanged(session, to: status)
                }
        }
    }

    @discardableResult
    internal func statusChanged(_ session: AgentSession, to status: AgentSessionStatus) -> Task<Void, Never>? {
        guard let body = Self.body(for: status, session: session) else {
            withdraw(sessionId: session.id)
            return nil
        }
        guard settings().isEnabled, !isOnScreen(session) else { return nil }
        let request = request(for: session, body: body)
        return Task { [weak self] in
            await self?.deliver(request, for: session)
        }
    }

    internal static func body(for status: AgentSessionStatus, session: AgentSession) -> String? {
        switch status {
        case .waitingOnYou:
            return String(localized: "The agent is waiting for your answer.")
        case .failed:
            let reason = session.viewModel.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !reason.isEmpty else { return String(localized: "The agent's reply failed.") }
            return String(format: String(localized: "The agent's reply failed: %@"), reason)
        case .working, .queued, .ready, .stopped:
            return nil
        }
    }

    internal static func identifier(for sessionId: UUID) -> String {
        identifierPrefix + sessionId.uuidString
    }

    private func request(for session: AgentSession, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = connectionName(session.connectionId)
        let subtitle = session.displayTitle
        if !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = body
        content.categoryIdentifier = Self.categoryId
        content.threadIdentifier = session.connectionId.uuidString
        content.userInfo = [
            Self.sessionIdKey: session.id.uuidString,
            Self.connectionIdKey: session.connectionId.uuidString
        ]
        return UNNotificationRequest(identifier: Self.identifier(for: session.id), content: content, trigger: nil)
    }

    private func deliver(_ request: UNNotificationRequest, for session: AgentSession) async {
        guard await authorization.ensureAuthorized() else { return }
        // The permission prompt can take minutes; the session may be on screen or answered by now.
        guard Self.body(for: session.status, session: session) != nil, !isOnScreen(session) else { return }
        do {
            try await presenter.post(request)
            delivered.insert(request.identifier)
        } catch {
            Self.logger.error("Could not post the agent notification: \(error.publicLogShape, privacy: .public)")
        }
    }

    private func withdraw(sessionId: UUID) {
        let identifier = Self.identifier(for: sessionId)
        guard delivered.remove(identifier) != nil else { return }
        presenter.removeDelivered(identifiers: [identifier])
    }
}

extension AgentAttentionNotifier: NotificationHandling {
    internal func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions {
        guard let session = session(from: notification.request.content.userInfo) else { return [.banner, .list] }
        return isOnScreen(session) ? [] : [.banner, .list]
    }

    internal func handle(_ response: UNNotificationResponse) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let session = session(from: response.notification.request.content.userInfo) else { return }
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        guard let host = WindowManager.shared.hostControllers(for: session.connectionId).first,
              let window = host.view.window else { return }
        window.makeKeyAndOrderFront(nil)
        host.selectHostedConnection(session.connectionId)
        host.setContentMode(.agent, for: session.connectionId)
        host.openAgentSession(id: session.id, connectionId: session.connectionId)
    }

    private func session(from userInfo: [AnyHashable: Any]) -> AgentSession? {
        guard let id = (userInfo[Self.sessionIdKey] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        return AgentSessionRegistry.shared.session(id: id)
    }
}

@MainActor
internal enum AgentSessionVisibility {
    internal static func isOnScreen(_ session: AgentSession) -> Bool {
        guard NSApp.isActive else { return false }
        return WindowManager.shared.hostControllers(for: session.connectionId).contains { host in
            guard let window = host.view.window, window.occlusionState.contains(.visible),
                  let workspace = host.workspaces.selected,
                  workspace.connectionId == session.connectionId else { return false }
            if workspace.displayedAgentSession?.id == session.id { return true }
            return host.isAssistantVisible
                && workspace.agentSessions.currentSession(for: session.connectionId)?.id == session.id
        }
    }
}
