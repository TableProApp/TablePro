//
//  OperationCompletionPolicy.swift
//  TablePro
//

import Foundation

internal enum CompletionSuppression: Equatable, Sendable {
    case cancelled
    case belowThreshold
    case resultOnScreen
    case notificationsOff
}

// The tab mark is the in-app channel and needs no permission or switch; the notification is the other.
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

// Pure and AppKit-free, so the rules are testable without a window or a permission.
internal enum OperationCompletionPolicy {
    internal static func decide(
        completion: OperationCompletion,
        visibility: ResultVisibility,
        settings: NotificationSettings
    ) -> CompletionDecision {
        // Checked before the threshold: a cancelled operation can still have run a long time.
        if case .cancelled = completion.outcome {
            return .suppressed(.cancelled)
        }

        guard completion.elapsed >= .seconds(settings.validatedThresholdSeconds) else {
            return .suppressed(.belowThreshold)
        }

        // The tab's inline error is the alert for a failure on screen; a notification would repeat it.
        guard !visibility.resultIsOnScreen else {
            return .suppressed(.resultOnScreen)
        }

        // A selected tab is not "somewhere you were not looking", and its mark would have nothing to clear it.
        let marksOwnerUnseen = !visibility.ownerIsSelectedInWindow

        guard settings.isEnabled else {
            return CompletionDecision(
                notification: nil, marksOwnerUnseen: marksOwnerUnseen, suppression: .notificationsOff
            )
        }

        return CompletionDecision(
            notification: plan(for: completion),
            marksOwnerUnseen: marksOwnerUnseen,
            suppression: nil
        )
    }

    // Keyed by owner and kind: one table tab owns queries, structure changes, saves and fetch-all.
    internal static func identifier(for completion: OperationCompletion) -> String {
        "\(identifierPrefix)\(completion.kind.rawValue).\(ownerKey(completion.owner))"
    }

    internal static let identifierPrefix = "com.TablePro.operation."
    internal static let copyErrorActionId = "operationCopyError"
    internal static let revealFileActionId = "operationRevealFile"

    // A category's actions are fixed at registration, so a shared one showed inert buttons on every banner.
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
        case .compareWindow(let id): return id.uuidString
        }
    }
}
