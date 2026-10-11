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
///
/// A result is matched to the call it answers within the round that raised it, never by id alone.
/// Several endpoints number every turn's calls from `call_0`, so a session's fifth round reuses the
/// ids of its first: matching across the whole transcript gave every earlier `call_0` the last
/// round's outcome, and a row that failed read as having run. A round writes its results into the
/// user turn straight after the assistant turn that proposed them, so the nearest unanswered call
/// with that id is the one being answered.
@MainActor
internal enum AgentArtifactProjection {
    private struct UnansweredCall {
        let toolUseId: String
        let statementOffset: Int?
        let sql: String?
        let isApproved: Bool
    }

    internal static func build(from turns: [ChatTurn]) -> AgentArtifact {
        var artifact = AgentArtifact()
        var unanswered: [UnansweredCall] = []

        for turn in turns {
            for block in turn.blocks {
                switch block.kind {
                case .toolUse(let use):
                    let sql = statementText(in: use.input)
                    var statementOffset: Int?
                    if let sql {
                        statementOffset = artifact.statements.count
                        artifact.statements.append(
                            ProposedStatement(
                                id: block.id.uuidString,
                                sql: sql,
                                toolName: use.name,
                                state: state(for: use.approvalState, result: nil)
                            )
                        )
                    }
                    unanswered.append(UnansweredCall(
                        toolUseId: use.id,
                        statementOffset: statementOffset,
                        sql: sql,
                        isApproved: use.approvalState == .approved
                    ))
                case .toolResult(let result):
                    guard let slot = unanswered.lastIndex(where: { $0.toolUseId == result.toolUseId })
                    else { continue }
                    let call = unanswered.remove(at: slot)
                    guard call.isApproved else { continue }
                    if let offset = call.statementOffset {
                        let statement = artifact.statements[offset]
                        artifact.statements[offset] = ProposedStatement(
                            id: statement.id,
                            sql: statement.sql,
                            toolName: statement.toolName,
                            state: state(for: .approved, result: result)
                        )
                    }
                    if let sql = call.sql, !result.isError {
                        artifact.runs.append(
                            AgentQueryRun(
                                id: call.statementOffset.map { artifact.statements[$0].id }
                                    ?? result.toolUseId,
                                sql: sql,
                                resultJSON: result.content
                            )
                        )
                    }
                default:
                    continue
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
