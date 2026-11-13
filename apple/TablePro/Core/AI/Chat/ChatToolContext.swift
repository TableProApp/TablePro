//
//  ChatToolContext.swift
//  TablePro
//

import Foundation

// `connectionId` is the only connection a tool may act on: a tool never reads `connection_id` from the model's input,
// which once let an approval for one connection run a statement on another. `ChatToolTarget` is the one door.
struct ChatToolContext: Sendable {
    typealias PolicyLookup = @Sendable (UUID) async -> AIConnectionPolicy?

    let connectionId: UUID?
    let bridge: MCPConnectionBridge
    let authPolicy: MCPAuthPolicy

    // Read only by an outside MCP server's audit entry, where the conversation that sent a call is the first question.
    let sessionId: UUID?

    // The mode the tool was resolved in, which also limits what it may run: Edit runs data statements only.
    let chatMode: AIChatMode

    // Only a Run or Always on this call's own card pre-clears the gate's confirmation: only then was the user shown
    // this statement on this connection. A grant from `aiAlwaysAllowedTools` is consent to the tool, not the statement.
    let approvalWasExplicit: Bool

    private let policyLookup: PolicyLookup

    init(
        connectionId: UUID?,
        bridge: MCPConnectionBridge,
        authPolicy: MCPAuthPolicy,
        chatMode: AIChatMode,
        sessionId: UUID? = nil,
        approvalWasExplicit: Bool = false,
        policyLookup: @escaping PolicyLookup = ChatToolContext.savedPolicy
    ) {
        self.connectionId = connectionId
        self.bridge = bridge
        self.authPolicy = authPolicy
        self.chatMode = chatMode
        self.sessionId = sessionId
        self.approvalWasExplicit = approvalWasExplicit
        self.policyLookup = policyLookup
    }

    // One context serves a round's blocks, some running at once, so each block's approval is bound to a copy.
    func carrying(approvalWasExplicit: Bool) -> ChatToolContext {
        ChatToolContext(
            connectionId: connectionId,
            bridge: bridge,
            authPolicy: authPolicy,
            chatMode: chatMode,
            sessionId: sessionId,
            approvalWasExplicit: approvalWasExplicit,
            policyLookup: policyLookup
        )
    }

    func aiPolicy(for connectionId: UUID) async -> AIConnectionPolicy? {
        await policyLookup(connectionId)
    }

    static let savedPolicy: PolicyLookup = { connectionId in
        await MainActor.run {
            AIConnectionAccessGate.policy(
                for: connectionId,
                connectionStorage: .shared,
                databaseManager: .shared,
                defaultPolicy: AppSettingsManager.shared.ai.defaultConnectionPolicy
            )
        }
    }

    var writeCapabilities: CallerCapabilities {
        approvalWasExplicit
            ? [.mayWrite, .mayRunDestructive, .confirmationPreCleared]
            : [.mayWrite, .mayRunDestructive]
    }
}
