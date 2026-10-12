//
//  PreConnectScriptConsent.swift
//  TablePro
//

import Foundation

internal extension DatabaseConnection {
    var trimmedPreConnectScript: String? {
        guard let script = preConnectScript else { return nil }
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasPreConnectScript: Bool {
        trimmedPreConnectScript != nil
    }
}

internal enum ConnectTrigger: Sendable, Equatable {
    /// A person, a script or a client asked for this connect and is waiting on it.
    case request
    /// TablePro started the connect on its own, so nobody is there to read the script.
    case background
}

@MainActor
internal protocol PreConnectScriptAsking {
    func ask(connectionName: String, script: String) async -> ConsentAnswer
}

internal enum PreConnectScriptConsentError: Error, Equatable, Sendable {
    case declined
    case unanswered
    case needsPerson
}

extension PreConnectScriptConsentError: LocalizedError {
    internal var errorDescription: String? {
        switch self {
        case .declined:
            String(localized: "The pre-connect script was not approved.")
        case .unanswered:
            String(localized: "Nobody answered the pre-connect script prompt in time.")
        case .needsPerson:
            String(localized: "TablePro does not run a pre-connect script on its own.")
        }
    }

    internal var recoverySuggestion: String? {
        switch self {
        case .declined:
            nil
        case .unanswered:
            String(localized: "Try again and answer the prompt in TablePro.")
        case .needsPerson:
            String(localized: "Connect again to review the script and run it.")
        }
    }
}

/// The one place that decides whether a connect may run the connection's pre-connect script, which
/// is arbitrary shell code. Every connect reaches it through `DatabaseManager.connectToSession`.
///
/// A gesture that asks before it starts connecting, the window and a link, leaves its approval here
/// for the connect it starts. Any other caller is asked at the connect: MCP, AppleScript, the
/// assistant, Compare and Copy To. A connect TablePro starts on its own is refused.
@MainActor
internal final class PreConnectScriptConsent {
    private struct Approval {
        let script: String
        let expiresAt: ContinuousClock.Instant
    }

    /// Long enough to outlast the extension prompt a gesture shows after this one.
    internal static let approvalLifetime: Duration = .seconds(120)

    private let asker: any PreConnectScriptAsking
    private let now: () -> ContinuousClock.Instant
    private var approvals: [UUID: Approval] = [:]

    internal init(
        asker: any PreConnectScriptAsking = PreConnectScriptPrompt(),
        now: @escaping () -> ContinuousClock.Instant = { .now }
    ) {
        self.asker = asker
        self.now = now
    }

    internal func confirm(_ connection: DatabaseConnection) async -> Bool {
        guard let script = connection.trimmedPreConnectScript else { return true }
        guard await asker.ask(connectionName: connection.name, script: script) == .approved else { return false }
        approvals[connection.id] = Approval(script: script, expiresAt: now() + Self.approvalLifetime)
        return true
    }

    internal func withdrawApproval(for connectionId: UUID) {
        approvals.removeValue(forKey: connectionId)
    }

    /// An approval is spent by one connect, and only for the script text it was given for.
    internal func authorize(_ connection: DatabaseConnection, trigger: ConnectTrigger) async throws {
        guard let script = connection.trimmedPreConnectScript else { return }
        if let approval = approvals.removeValue(forKey: connection.id),
           approval.script == script,
           approval.expiresAt > now() {
            return
        }
        guard trigger == .request else { throw PreConnectScriptConsentError.needsPerson }
        switch await asker.ask(connectionName: connection.name, script: script) {
        case .approved:
            return
        case .declined:
            throw PreConnectScriptConsentError.declined
        case .unanswered:
            throw PreConnectScriptConsentError.unanswered
        }
    }
}
