//
//  AgentArtifactCache.swift
//  TablePro
//

import Combine
import Foundation

/// The result column's projection of a session's transcript, rebuilt only when the transcript
/// changes in a way the projection can see.
///
/// `AgentArtifactProjection` walks every turn and `AgentResultDecoder` parses a run's whole result,
/// and the column used to run both from computed properties read in `body`, so every redraw did both
/// again, the ones a streaming reply causes included. The key is what the projection reads and
/// nothing more: the session, the number of turns, and every call and result block with the state it
/// is in. Text arriving in the turn that is streaming moves none of it.
///
/// A count of turns alone is not enough of a key. A call waiting for its answer sits in the turn that
/// is still open, and a Copilot result lands in the turn that made the call, so a key of turns would
/// hold a proposed statement off the column until some later turn arrived. The blocks are named by
/// their own ids rather than the provider's call ids, because several providers number every round's
/// calls from `call_0`, and two conversations can agree on all of them.
///
/// The session is in the key because the column outlives a session switch: the pane is one hosting
/// controller per window, drawing whichever session is open, and this is that pane's state. It is an
/// `ObservableObject` only so the pane can keep it as a `@StateObject`. It publishes nothing, because
/// the pane already redraws when the session does, and all this decides is how much work a redraw is.
@MainActor
internal final class AgentArtifactCache: ObservableObject {
    /// Nothing here is `@Published`, so the conformance names its publisher itself: with no published
    /// property the compiler cannot infer one, and the pane needs the conformance to hold this as a
    /// `@StateObject` and get one instance for as long as the column lives.
    internal typealias ObjectWillChangePublisher = ObservableObjectPublisher

    internal struct Key: Equatable {
        internal let sessionId: UUID
        internal let turnCount: Int
        internal let toolBlocks: [ToolBlockState]
    }

    internal enum ToolBlockState: Equatable {
        case call(blockId: UUID, approval: ToolApprovalState)
        case result(blockId: UUID)
    }

    private let project: @MainActor ([ChatTurn]) -> AgentArtifact
    private let decode: (String) -> AgentResultPayload

    private var key: Key?
    private var artifact = AgentArtifact()
    private var payloads: [String: AgentResultPayload] = [:]

    internal init(
        project: @escaping @MainActor ([ChatTurn]) -> AgentArtifact = AgentArtifactProjection.build(from:),
        decode: @escaping (String) -> AgentResultPayload = AgentResultDecoder.payload(fromResultJSON:)
    ) {
        self.project = project
        self.decode = decode
    }

    /// The session's statements and runs, projected again only when the key has moved.
    internal func artifact(for session: AgentSession) -> AgentArtifact {
        let turns = session.viewModel.messages
        let next = Self.key(sessionId: session.id, turns: turns)
        guard next != key else { return artifact }
        if key?.sessionId != next.sessionId {
            payloads = [:]
        }
        key = next
        artifact = project(turns)
        let liveRuns = Set(artifact.runs.map(\.id))
        payloads = payloads.filter { liveRuns.contains($0.key) }
        return artifact
    }

    /// Decoded the first time the column asks for it and then kept: a run's result does not change
    /// once it has landed, and a new transcript brings runs with new ids.
    internal func payload(for run: AgentQueryRun) -> AgentResultPayload {
        if let cached = payloads[run.id] {
            return cached
        }
        let decoded = decode(run.resultJSON)
        payloads[run.id] = decoded
        return decoded
    }

    internal static func key(sessionId: UUID, turns: [ChatTurn]) -> Key {
        var toolBlocks: [ToolBlockState] = []
        for turn in turns {
            for block in turn.blocks {
                switch block.kind {
                case .toolUse(let use):
                    toolBlocks.append(.call(blockId: block.id, approval: use.approvalState))
                case .toolResult:
                    toolBlocks.append(.result(blockId: block.id))
                case .text, .attachment, .reasoning, .image, .sqlWalkthrough:
                    continue
                }
            }
        }
        return Key(sessionId: sessionId, turnCount: turns.count, toolBlocks: toolBlocks)
    }
}
