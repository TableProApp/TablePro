//
//  OperationCompletionReporter.swift
//  TablePro
//

import AppKit
import Foundation
import os
import UserNotifications

// Every long-running surface reports here, so the rules live in OperationCompletionPolicy alone.
@MainActor
internal final class OperationCompletionReporter {
    internal static let shared = OperationCompletionReporter()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "OperationNotifications")

    private let presenter: any UserNotificationPresenting
    private let authorization: NotificationAuthorization
    private let categories: NotificationCategoryRegistry
    private let settings: () -> NotificationSettings
    private let resolveVisibility: (OperationOwner, UUID) -> ResultVisibility
    private let markUnseen: (OperationOwner, TabUnseenOutcome) -> Void

    private var deliveredIdentifiers: Set<String> = []

    internal init(
        presenter: any UserNotificationPresenting = SystemNotificationPresenter.shared,
        authorization: NotificationAuthorization = .shared,
        categories: NotificationCategoryRegistry = .shared,
        settings: (() -> NotificationSettings)? = nil,
        resolveVisibility: ((OperationOwner, UUID) -> ResultVisibility)? = nil,
        markUnseen: ((OperationOwner, TabUnseenOutcome) -> Void)? = nil
    ) {
        self.presenter = presenter
        self.authorization = authorization
        self.categories = categories
        self.settings = settings ?? { AppSettingsManager.shared.notifications }
        self.resolveVisibility = resolveVisibility ?? {
            ResultVisibilityResolver.resolve(owner: $0, connectionId: $1)
        }
        self.markUnseen = markUnseen ?? { OperationUnseenMarker.mark($0, outcome: $1) }
    }

    internal func setUp() {
        categories.register(Self.notificationCategories(), owner: "operations")
        for categoryId in OperationCompletionPolicy.Category.all {
            NotificationRouter.shared.register(self, forCategory: categoryId)
        }
    }

    @discardableResult
    internal func report(_ completion: OperationCompletion) -> Task<Void, Never>? {
        let visibility = resolveVisibility(completion.owner, completion.connectionId)
        let decision = OperationCompletionPolicy.decide(
            completion: completion,
            visibility: visibility,
            settings: settings()
        )

        if decision.marksOwnerUnseen, let outcome = OperationUnseenMarker.outcome(of: completion.outcome) {
            markUnseen(completion.owner, outcome)
        }

        guard let plan = decision.notification else { return nil }

        return Task { [weak self] in
            await self?.deliver(plan, for: completion)
        }
    }

    private func deliver(_ plan: NotificationPlan, for completion: OperationCompletion) async {
        guard await authorization.ensureAuthorized() else {
            requestDockAttention()
            return
        }

        // The permission dialog can take minutes, so visibility is read again after it.
        let current = resolveVisibility(completion.owner, completion.connectionId)
        guard !current.resultIsOnScreen else { return }

        do {
            try await presenter.post(Self.request(for: plan))
            deliveredIdentifiers.insert(plan.identifier)
        } catch {
            Self.logger.error("Failed to post completion notification: \(error.localizedDescription)")
        }
    }

    // No API reports a banner swallowed by Focus; a denied permission is the one state the app can see.
    private func requestDockAttention() {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }

    internal func clearDelivered(for owner: OperationOwner) {
        let prefix = OperationCompletionPolicy.identifierPrefix
        let ownerSuffix = Self.ownerSuffix(owner)
        let matching = deliveredIdentifiers.filter {
            $0.hasPrefix(prefix) && $0.hasSuffix(ownerSuffix)
        }
        guard !matching.isEmpty else { return }
        presenter.removeDelivered(identifiers: Array(matching))
        deliveredIdentifiers.subtract(matching)
    }

    private static func ownerSuffix(_ owner: OperationOwner) -> String {
        switch owner {
        case .tab(_, let tabId): return tabId.uuidString
        case .connection(let connectionId): return connectionId.uuidString
        case .compareWindow(let id): return id.uuidString
        }
    }

    private static func request(for plan: NotificationPlan) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = plan.title
        if let subtitle = plan.subtitle {
            content.subtitle = subtitle
        }
        content.body = plan.body
        content.categoryIdentifier = plan.categoryIdentifier
        content.threadIdentifier = plan.threadIdentifier
        content.userInfo = OperationNotificationPayload(plan: plan).userInfo
        return UNNotificationRequest(identifier: plan.identifier, content: content, trigger: nil)
    }

    // No View Results action: the default click opens the app. A category's actions are fixed at registration, hence three.
    private static func notificationCategories() -> Set<UNNotificationCategory> {
        let copyError = UNNotificationAction(
            identifier: OperationCompletionPolicy.copyErrorActionId,
            title: String(localized: "Copy Error"),
            options: []
        )
        let reveal = UNNotificationAction(
            identifier: OperationCompletionPolicy.revealFileActionId,
            title: String(localized: "Show in Finder"),
            options: []
        )
        return [
            category(OperationCompletionPolicy.Category.plain, actions: []),
            category(OperationCompletionPolicy.Category.failed, actions: [copyError]),
            category(OperationCompletionPolicy.Category.producedFile, actions: [reveal])
        ]
    }

    private static func category(_ identifier: String, actions: [UNNotificationAction]) -> UNNotificationCategory {
        UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [], options: [])
    }
}
