//
//  OperationCompletionPolicy.swift
//  TablePro
//

import Foundation

internal enum CompletionSuppression: Equatable, Sendable {
    case cancelled
    case belowThreshold
    case resultOnScreen
    case kindDisabled
}

/// What should happen now that an operation has finished.
///
/// The tab marker and the notification are separate channels on purpose. The marker is the
/// in-app one and does not depend on notification permission, on the per-kind toggles, or on
/// the user ever having seen a banner, so a user who denied notifications still gets told which
/// tab finished while they were away.
internal struct CompletionDecision: Equatable {
    internal var notification: NotificationPlan?
    internal var marksOwnerUnseen: Bool
    internal var suppression: CompletionSuppression?

    internal static func suppressed(_ reason: CompletionSuppression) -> CompletionDecision {
        CompletionDecision(notification: nil, marksOwnerUnseen: false, suppression: reason)
    }
}

internal struct NotificationPlan: Equatable, Sendable {
    internal let identifier: String
    internal let categoryIdentifier: String
    internal let threadIdentifier: String
    internal let title: String
    internal let subtitle: String?
    internal let body: String
    internal let owner: OperationOwner
    internal let failureReason: String?
    internal let revealURL: URL?
}

/// Every rule about whether a finished operation is worth telling the user about. Pure and
/// AppKit-free so all of it is testable without a window, a notification permission, or a run
/// loop, which is the only way these rules stay honest on CI.
internal enum OperationCompletionPolicy {
    internal static func decide(
        completion: OperationCompletion,
        visibility: ResultVisibility,
        settings: NotificationSettings
    ) -> CompletionDecision {
        /// Work the user stopped themselves is never news. This is checked before the threshold
        /// because a cancelled operation has still been running for a long time.
        if case .cancelled = completion.outcome {
            return .suppressed(.cancelled)
        }

        guard completion.elapsed >= .seconds(settings.validatedThresholdSeconds) else {
            return .suppressed(.belowThreshold)
        }

        /// The result is already in front of the user. A failure is suppressed here too, and
        /// deliberately: the tab shows an inline error banner, which is the alert the HIG asks
        /// for, and a notification on top of it would be the same news twice.
        guard !visibility.resultIsOnScreen else {
            return .suppressed(.resultOnScreen)
        }

        /// The mark says "this finished somewhere you were not looking", and a tab the user
        /// already has selected is not that: they see the result the moment they come back to the
        /// app. Marking it anyway left a dot nothing could clear, because the only clear paths are
        /// keyed on a tab change and returning to the app is not one.
        let marksOwnerUnseen = !visibility.ownerIsSelectedInWindow

        guard settings.isEnabled(for: completion.kind) else {
            return CompletionDecision(
                notification: nil, marksOwnerUnseen: marksOwnerUnseen, suppression: .kindDisabled
            )
        }

        return CompletionDecision(
            notification: plan(for: completion),
            marksOwnerUnseen: marksOwnerUnseen,
            suppression: nil
        )
    }

    /// Scoped by owner AND kind. Owner alone looked right and was wrong: one table tab owns its
    /// query, its structure changes, its row saves and its fetch-all, so a single owner-keyed
    /// identifier lets a later DDL completion silently replace a query completion the user had
    /// not read yet. Re-running the same kind on the same owner is the only case that should
    /// replace, and that is exactly what this key expresses.
    internal static func identifier(for completion: OperationCompletion) -> String {
        "\(identifierPrefix)\(completion.kind.rawValue).\(ownerKey(completion.owner))"
    }

    internal static let identifierPrefix = "com.TablePro.operation."
    internal static let copyErrorActionId = "operationCopyError"
    internal static let revealFileActionId = "operationRevealFile"

    /// Three categories, because a category's actions are fixed when it is registered and the
    /// content only picks which category it belongs to. One shared category meant every success
    /// notification carried a Copy Error and a Show in Finder button whose handlers returned
    /// without doing anything: visibly present, completely inert.
    internal enum Category {
        internal static let plain = "com.TablePro.operationFinished"
        internal static let failed = "com.TablePro.operationFailed"
        internal static let producedFile = "com.TablePro.operationProducedFile"

        internal static let all = [plain, failed, producedFile]
    }

    internal static func categoryId(for outcome: OperationOutcome) -> String {
        switch outcome {
        case .failed: return Category.failed
        case .succeeded(let summary): return summary.fileURL == nil ? Category.plain : Category.producedFile
        case .cancelled: return Category.plain
        }
    }

    private static func plan(for completion: OperationCompletion) -> NotificationPlan {
        NotificationPlan(
            identifier: identifier(for: completion),
            categoryIdentifier: categoryId(for: completion.outcome),
            threadIdentifier: completion.connectionId.uuidString,
            title: OperationCompletionCopy.title(for: completion),
            subtitle: OperationCompletionCopy.subtitle(for: completion),
            body: OperationCompletionCopy.body(for: completion),
            owner: completion.owner,
            failureReason: failureReason(completion.outcome),
            revealURL: revealURL(completion.outcome)
        )
    }

    private static func failureReason(_ outcome: OperationOutcome) -> String? {
        guard case .failed(let reason) = outcome else { return nil }
        return reason
    }

    private static func revealURL(_ outcome: OperationOutcome) -> URL? {
        guard case .succeeded(let summary) = outcome else { return nil }
        return summary.fileURL
    }

    private static func ownerKey(_ owner: OperationOwner) -> String {
        switch owner {
        case .tab(_, let tabId): return tabId.uuidString
        case .connection(let connectionId): return connectionId.uuidString
        }
    }
}
