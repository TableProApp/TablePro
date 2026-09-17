//
//  AgentArtifact.swift
//  TablePro
//

import Foundation

/// What a session proposed, in the order it proposed it.
internal struct ProposedStatement: Identifiable, Equatable {
    internal let id: String
    internal let sql: String
    internal let toolName: String
    internal let state: ProposedStatementState
}

/// Where a proposed statement got to. The vocabulary the pane and the approval card share, so the
/// button that produced a state and the state itself cannot be named differently.
internal enum ProposedStatementState: Equatable {
    case waiting
    case ran
    case rejected
    case notAllowed(reason: String)
    case failed(reason: String)

    internal var title: String {
        switch self {
        case .waiting: String(localized: "Waiting")
        case .ran: String(localized: "Ran")
        case .rejected: String(localized: "Rejected")
        case .notAllowed: String(localized: "Not allowed")
        case .failed: String(localized: "Failed")
        }
    }

    internal var symbolName: String {
        switch self {
        case .waiting: "hand.raised"
        case .ran: "checkmark.circle"
        case .rejected: "slash.circle"
        case .notAllowed: "lock"
        case .failed: "exclamationmark.triangle"
        }
    }

    internal var isDestructiveOutcome: Bool {
        switch self {
        case .notAllowed, .failed: true
        case .waiting, .ran, .rejected: false
        }
    }
}

/// One query the session ran, and what came back.
internal struct AgentQueryRun: Identifiable, Equatable {
    internal let id: String
    internal let sql: String
    internal let resultJSON: String
}

/// Everything the result pane draws, projected from the session's own turns.
internal struct AgentArtifact: Equatable {
    internal var statements: [ProposedStatement] = []
    internal var runs: [AgentQueryRun] = []

    internal var isEmpty: Bool {
        statements.isEmpty && runs.isEmpty
    }
}

/// Reads the transcript and answers what the pane should show.
///
/// A pure function over the turns rather than a second store, which is what makes a restored
/// session's pane correct with no replay: the transcript is what was restored, and there is one
/// record of "waiting" instead of two that can disagree.
@MainActor
internal enum AgentArtifactProjection {
    internal static func build(from turns: [ChatTurn]) -> AgentArtifact {
        var artifact = AgentArtifact()
        var resultsByToolUseId: [String: ToolResultBlock] = [:]

        for turn in turns {
            for block in turn.blocks {
                guard case .toolResult(let result) = block.kind else { continue }
                resultsByToolUseId[result.toolUseId] = result
            }
        }

        for turn in turns {
            for block in turn.blocks {
                guard case .toolUse(let use) = block.kind else { continue }
                guard let sql = statementText(in: use.input) else { continue }
                let result = resultsByToolUseId[use.id]
                artifact.statements.append(
                    ProposedStatement(
                        id: use.id,
                        sql: sql,
                        toolName: use.name,
                        state: state(for: use.approvalState, result: result)
                    )
                )
                if case .approved = use.approvalState,
                   let result, !result.isError {
                    artifact.runs.append(
                        AgentQueryRun(id: use.id, sql: sql, resultJSON: result.content)
                    )
                }
            }
        }
        return artifact
    }

    private static func state(
        for approval: ToolApprovalState,
        result: ToolResultBlock?
    ) -> ProposedStatementState {
        switch approval {
        case .pending:
            return .waiting
        case .cancelled:
            return .rejected
        case .denied(let reason):
            return .notAllowed(reason: reason)
        case .approved:
            guard let result else { return .waiting }
            return result.isError ? .failed(reason: result.content) : .ran
        }
    }

    private static func statementText(in input: JsonValue) -> String? {
        guard case .object(let fields) = input,
              case .string(let query)? = fields["query"] else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : query
    }
}
