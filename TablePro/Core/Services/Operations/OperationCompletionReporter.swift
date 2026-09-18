//
//  OperationCompletionReporter.swift
//  TablePro
//

import AppKit
import Foundation
import os
import UserNotifications

/// The one place a finished operation is turned into whatever the user should see.
///
/// Every long-running surface reports here and nowhere else, so the rules live in
/// `OperationCompletionPolicy` alone rather than being restated at each of the fifteen places an
/// operation can end.
@MainActor
internal final class OperationCompletionReporter {
    internal static let shared = OperationCompletionReporter()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "OperationNotifications")

    private let presenter: any UserNotificationPresenting
    private let authorization: NotificationAuthorization
    private let categories: NotificationCategoryRegistry
    private let settings: () -> NotificationSettings
    private let resolveVisibility: (OperationOwner, UUID) -> ResultVisibility
    private let markUnseen: (OperationOwner) -> Void

    private var deliveredIdentifiers: Set<String> = []

    internal init(
        presenter: any UserNotificationPresenting = SystemNotificationPresenter.shared,
        authorization: NotificationAuthorization = .shared,
        categories: NotificationCategoryRegistry = .shared,
        settings: (() -> NotificationSettings)? = nil,
        resolveVisibility: ((OperationOwner, UUID) -> ResultVisibility)? = nil,
        markUnseen: ((OperationOwner) -> Void)? = nil
    ) {
        self.presenter = presenter
        self.authorization = authorization
        self.categories = categories
        self.settings = settings ?? { AppSettingsManager.shared.notifications }
        self.resolveVisibility = resolveVisibility ?? {
            ResultVisibilityResolver.resolve(owner: $0, connectionId: $1)
        }
        self.markUnseen = markUnseen ?? { OperationUnseenMarker.mark($0) }
    }

    internal func setUp() {
        categories.register(Self.notificationCategories(), owner: "operations")
        for categoryId in OperationCompletionPolicy.Category.all {
            NotificationRouter.shared.register(self, forCategory: categoryId)
        }
    }

    internal func report(_ completion: OperationCompletion) {
        let visibility = resolveVisibility(completion.owner, completion.connectionId)
        let decision = OperationCompletionPolicy.decide(
            completion: completion,
            visibility: visibility,
            settings: settings()
        )

        if decision.marksOwnerUnseen {
            markUnseen(completion.owner)
        }

        guard let plan = decision.notification else { return }

        Task { [weak self] in
            await self?.deliver(plan, for: completion)
        }
    }

    private func deliver(_ plan: NotificationPlan, for completion: OperationCompletion) async {
        guard await authorization.ensureAuthorized() else {
            requestDockAttention()
            return
        }

        /// The permission dialog is modal and the user may have taken minutes over it, so the
        /// visibility read from before the await says nothing about now. A user who granted
        /// permission and then went back to the tab must not be told about the result they are
        /// looking at.
        let current = resolveVisibility(completion.owner, completion.connectionId)
        guard !current.resultIsOnScreen else { return }

        do {
            try await presenter.post(Self.request(for: plan))
            deliveredIdentifiers.insert(plan.identifier)
        } catch {
            Self.logger.error("Failed to post completion notification: \(error.localizedDescription)")
        }
    }

    /// The only honest fallback available. There is no API that reports a notification was
    /// swallowed by a Focus mode, so this keys on the one state the app can actually observe:
    /// permission was denied outright. `requestUserAttention` is documented as being for an
    /// application that is not already active, which is exactly the case the policy just proved.
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

    /// No "View Results" action anywhere. The HIG is explicit that you should avoid an action
    /// that merely opens your app, and the default click already does exactly that.
    ///
    /// Three categories rather than one, because a category's actions are fixed at registration
    /// and only the content picks its category. Sharing one meant a plain success notification
    /// offered Copy Error and Show in Finder, both of which did nothing at all.
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
