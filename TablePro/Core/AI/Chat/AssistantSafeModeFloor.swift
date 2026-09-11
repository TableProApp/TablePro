//
//  AssistantSafeModeFloor.swift
//  TablePro
//

import Foundation

/// Assistant mode promises that a write the assistant proposes waits for a human. On a connection
/// left at `.silent`, which is the default in both the initializer and the decoder, that promise
/// was false: `requiresConfirmation` is `false` there, so the approval path returned `.approved`
/// for a `.write` tool with no user interaction at all.
///
/// The floor is applied where the level is read, not by mutating the stored connection. Nothing is
/// written to `ConnectionStorage`, so nothing syncs, nothing has to be restored after a crash, and
/// the user's own level is still their own level the moment they leave the mode.
internal enum AssistantSafeModeFloor {
    /// Confirm Writes. High enough that every proposed write stops for a human, low enough that it
    /// adds no authentication step the user did not ask for.
    internal static let floor: SafeModeLevel = .alert

    /// Pure, so the rule is testable without a window, a connection record or UserDefaults.
    ///
    /// Both floors are composed here, in one place. An administrator's
    /// `com.TablePro.policy.minimumSafeModeLevel` is a floor with exactly the same shape, and every
    /// other execution path already applies it through `ExecutionGateProvider`. The chat tools hand
    /// the gate `.confirmationPreCleared`, so the gate's confirmation arm is skipped for them and
    /// this is the only place a managed Alert floor can still be enforced on an AI-proposed write.
    /// Reading the raw level here left a managed "confirm every write" as a no-op for the assistant.
    internal static func effectiveLevel(
        stored: SafeModeLevel,
        assistantModeActive: Bool,
        policy: any ManagedPolicyReading = ManagedPolicyReader.shared
    ) -> SafeModeLevel {
        let managed = ManagedPolicyResolver.effectiveSafeModeLevel(
            connectionLevel: stored,
            policy: policy
        )
        guard assistantModeActive else { return managed }
        return managed.raised(toFloor: floor)
    }

    /// Whether a floor, rather than the user's own choice, is what is asking for the confirmation.
    /// The approval path needs this separately from the level itself: a grant the user made for
    /// their own level must not silently switch off a floor they did not set.
    internal static func floorRaisedLevel(
        stored: SafeModeLevel,
        assistantModeActive: Bool,
        policy: any ManagedPolicyReading = ManagedPolicyReader.shared
    ) -> Bool {
        effectiveLevel(stored: stored, assistantModeActive: assistantModeActive, policy: policy) != stored
    }

    /// `WorkspaceContentModeStore` is the single record of which surface a connection is on, and it
    /// is written on every mode change, so it answers this without a second registry to keep in
    /// step. A connection no window is hosting still reads whatever it was last left in, which errs
    /// toward the floor being on: there is no session to gate in that case, and a floor that is on
    /// when it need not be costs a confirmation, while one that is off when it should be on costs
    /// the user their data.
    @MainActor
    internal static func isActive(
        for connectionId: UUID,
        store: WorkspaceContentModeStore = .shared
    ) -> Bool {
        store.mode(connectionId: connectionId) == .assistant
    }

    @MainActor
    internal static func effectiveLevel(
        live: SafeModeLevel,
        connectionId: UUID,
        store: WorkspaceContentModeStore = .shared,
        policy: any ManagedPolicyReading = ManagedPolicyReader.shared
    ) -> SafeModeLevel {
        effectiveLevel(
            stored: live,
            assistantModeActive: isActive(for: connectionId, store: store),
            policy: policy
        )
    }

    @MainActor
    internal static func floorRaisedLevel(
        live: SafeModeLevel,
        connectionId: UUID,
        store: WorkspaceContentModeStore = .shared,
        policy: any ManagedPolicyReading = ManagedPolicyReader.shared
    ) -> Bool {
        floorRaisedLevel(
            stored: live,
            assistantModeActive: isActive(for: connectionId, store: store),
            policy: policy
        )
    }
}
