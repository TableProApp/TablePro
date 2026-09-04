//
//  AgentArtifact.swift
//  TablePro
//

import Foundation

/// Where a statement the session proposed has got to.
///
/// Derived from the transcript, never stored beside it. The approval state lives on the tool-use
/// block, which the approval path already mutates in place, so there is one record of "waiting" and
/// the pane cannot drift from the gate.
internal enum ProposedStatementState: Equatable, Sendable {
    case waiting
    case running
    case ran
    case rejected
    case denied(reason: String)
    case failed(message: String)

    internal var localizedTitle: String {
        switch self {
        case .waiting: return String(localized: "Waiting")
        case .running: return String(localized: "Running")
        case .ran: return String(localized: "Ran")
        case .rejected: return String(localized: "Rejected")
        case .denied: return String(localized: "Not allowed")
        case .failed: return String(localized: "Failed")
        }
    }

    internal var detail: String? {
        switch self {
        case .denied(let reason): return reason
        case .failed(let message): return message
        case .waiting, .running, .ran, .rejected: return nil
        }
    }

    internal var icon: String {
        switch self {
        case .waiting: return "hand.raised"
        case .running: return "circle.dotted"
        case .ran: return "checkmark.circle"
        case .rejected: return "slash.circle"
        case .denied: return "lock"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

/// One statement the session proposed, in the order it proposed it.
internal struct ProposedStatement: Identifiable, Equatable, Sendable {
    internal let id: String
    internal let toolName: String
    internal let sql: String
    internal let connectionName: String
    internal let tier: QueryTier
    internal let state: ProposedStatementState

    internal var isDestructive: Bool { tier == .destructive }
    internal var awaitsDecision: Bool { state == .waiting }
}

/// A step the session has taken. Consecutive reads collapse into one row, because a session that
/// looked at nine tables is one step to a reader and nine rows of noise.
internal struct AgentStep: Identifiable, Equatable, Sendable {
    internal enum State: Equatable, Sendable {
        case done
        case inFlight
        case waitingOnYou
        case failed
    }

    internal let id: String
    internal let title: String
    internal let detail: String?
    internal let state: State
}

/// A query the session ran, with what the engine said about it. The rows themselves stay in
/// `resultJSON` and are decoded by the row that renders them: a transcript holds every result the
/// session ever got, and decoding all of them to draw a list would be paid on every keystroke.
internal struct QueryRun: Identifiable, Equatable, Sendable {
    internal let id: String
    internal let sql: String
    internal let resultJSON: String
    internal let isError: Bool
    internal let planText: String?
}

/// The decoded body of one query result: what the engine returned, and what it cost.
///
/// Decoded on demand by the row that shows it rather than when the artifact is built. A transcript
/// holds every result the session ever got, and decoding all of them to draw a list would be paid
/// again on every keystroke in the composer.
internal struct QueryRunSummary: Equatable, Sendable {
    internal let columns: [String]
    internal let rows: [[String]]
    internal let rowCount: Int
    internal let rowsAffected: Int
    internal let durationMs: Double?
    internal let isTruncated: Bool
    internal let statusMessage: String?

    /// The most rows one result renders in the pane. A larger result is still complete on the
    /// clipboard and in a query tab; what this cap protects is the conversation, which shares the
    /// window's layout pass with the pane.
    internal static let renderedRowLimit = 100

    internal static func decode(_ json: String) -> QueryRunSummary? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let columns = (object["columns"] as? [Any])?.compactMap { $0 as? String } ?? []
        let rawRows = object["rows"] as? [Any] ?? []
        let rows: [[String]] = rawRows.prefix(renderedRowLimit).map { row in
            (row as? [Any] ?? []).map(Self.cellText)
        }
        return QueryRunSummary(
            columns: columns,
            rows: rows,
            rowCount: object["row_count"] as? Int ?? rawRows.count,
            rowsAffected: object["rows_affected"] as? Int ?? 0,
            durationMs: object["execution_time_ms"] as? Double,
            isTruncated: object["is_truncated"] as? Bool ?? false,
            statusMessage: object["status_message"] as? String
        )
    }

    /// A cell arrives as a JSON string, number, bool or null. `NSNull` is rendered as the word the
    /// grid uses rather than as an empty cell, because an empty string is a value a column can hold.
    private static func cellText(_ value: Any) -> String {
        switch value {
        case is NSNull: return String(localized: "NULL")
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return String(describing: value)
        }
    }
}

/// What a DDL statement would change. Empty `lines` means the reader was not certain, and the raw
/// statement is shown instead of a claim about it.
internal struct SchemaChangePreview: Identifiable, Equatable, Sendable {
    internal let id: String
    internal let sql: String
    internal let target: String?
    internal let lines: [SchemaChangeLine]
    internal let isDestructive: Bool

    /// The same preview under the id of the call that proposed it. What a statement would change is
    /// a property of the statement, so it is read once and named per call; the id is what the pane
    /// lists it by and the only part that belongs to the call.
    ///
    /// The lines are renamed with it. `DDLChangeReader` builds each line's id as `"\(id).\(n)"`, so
    /// leaving them alone would give every preview of a given statement the same line ids as every
    /// other, which is the kind of collision `ForEach` resolves by keeping the wrong row.
    internal func identified(as id: String) -> SchemaChangePreview {
        SchemaChangePreview(
            id: id,
            sql: sql,
            target: target,
            lines: lines.enumerated().map { index, line in
                SchemaChangeLine(id: "\(id).\(index)", kind: line.kind, text: line.text)
            },
            isDestructive: isDestructive
        )
    }
}

internal struct SchemaChangeLine: Identifiable, Equatable, Sendable {
    internal enum Kind: Equatable, Sendable {
        case adds
        case removes
        case changes
    }

    internal let id: String
    internal let kind: Kind
    internal let text: String

    internal var isDestructive: Bool { kind == .removes }
}

/// Everything the four segments render, built in one pass over the transcript.
internal struct AgentArtifact: Equatable, Sendable {
    internal var statements: [ProposedStatement] = []
    internal var steps: [AgentStep] = []
    internal var runs: [QueryRun] = []
    internal var schemaChanges: [SchemaChangePreview] = []

    internal var isEmpty: Bool {
        statements.isEmpty && steps.isEmpty && runs.isEmpty && schemaChanges.isEmpty
    }
}

/// Builds the artifact from the session's own turns.
///
/// A projection rather than a second model. The first version of this phase proposed an observable
/// store fed by the stream, which is two representations of the same facts and one of them stale
/// after a restore; reading the transcript means a restored session's pane is correct with no
/// replay, because the transcript is what was restored.
@MainActor
internal enum AgentArtifactProjection {
    /// Tools whose calls the pane speaks about. Everything else is a read and belongs in the step
    /// timeline only.
    private static let statementTools: Set<String> = ["execute_query", "confirm_destructive_operation"]
    private static let explainTool = "explain_query"

    /// What a statement means, which is the expensive half of this projection and the half that
    /// never changes once the statement is written.
    private struct StatementAnalysis {
        let tier: QueryTier
        /// Nil when the statement changes no schema. Carries no id: the id belongs to the call, and
        /// the same statement proposed twice is analysed once and labelled twice.
        let schemaChange: SchemaChangePreview?
    }

    /// Memoizes that analysis across the passes this projection is run on.
    ///
    /// The pane recomputes on every render so it can never disagree with the transcript, and that
    /// is the right call, but the transcript is rewritten twenty times a second while a reply
    /// streams (`AIChatViewModel.streamFlushInterval` is 50ms). Without this, every one of those
    /// passes ran `QueryClassifier.classifyTier` and the whole of `DDLChangeReader.preview` over
    /// every statement the conversation had ever proposed, so the cost of drawing the pane grew
    /// with the length of the conversation and was paid at 20Hz.
    ///
    /// Keyed by the statement and the engine, which is everything the analysis reads, so a hit is
    /// exact rather than probable. Streaming text changes neither, so the cache answers every pass
    /// between one tool call and the next.
    private static var analyses: [AnalysisKey: StatementAnalysis] = [:]

    private struct AnalysisKey: Hashable {
        let sql: String
        let databaseType: String
    }

    /// Statements are short and a conversation proposes few, but a session left open for a day
    /// should not grow this without bound. Cleared wholesale rather than evicted one at a time: the
    /// next pass repopulates only what the transcript still holds, which is the working set.
    private static let analysisCapacity = 512

    private static func analysis(sql: String, databaseType: DatabaseType) -> StatementAnalysis {
        let key = AnalysisKey(sql: sql, databaseType: databaseType.rawValue)
        if let cached = analyses[key] { return cached }
        let tier = QueryClassifier.classifyTier(sql, databaseType: databaseType)
        let analysis = StatementAnalysis(
            tier: tier,
            schemaChange: tier == .destructive || DDLChangeReader.looksLikeDDL(sql)
                ? DDLChangeReader.preview(id: "", sql: sql, databaseType: databaseType)
                : nil
        )
        if analyses.count >= analysisCapacity { analyses.removeAll(keepingCapacity: true) }
        analyses[key] = analysis
        return analysis
    }

    internal static func build(
        from messages: [ChatTurn],
        connectionName: String,
        databaseType: DatabaseType
    ) -> AgentArtifact {
        var artifact = AgentArtifact()
        var results: [String: ToolResultBlock] = [:]
        var uses: [(block: ToolUseBlock, order: Int)] = []

        var order = 0
        for turn in messages {
            for block in turn.blocks {
                switch block.kind {
                case .toolUse(let use):
                    uses.append((use, order))
                    order += 1
                case .toolResult(let result):
                    results[result.toolUseId] = result
                default:
                    continue
                }
            }
        }

        for entry in uses {
            let use = entry.block
            let result = results[use.id]
            let sql = Self.statementText(from: use)

            if Self.statementTools.contains(use.name), let sql {
                let analysis = Self.analysis(sql: sql, databaseType: databaseType)
                artifact.statements.append(
                    ProposedStatement(
                        id: use.id,
                        toolName: use.name,
                        sql: sql,
                        connectionName: connectionName,
                        tier: analysis.tier,
                        state: Self.state(for: use, result: result)
                    )
                )
                if let schemaChange = analysis.schemaChange {
                    artifact.schemaChanges.append(schemaChange.identified(as: use.id))
                }
            }

            if let sql, let result, !result.isError,
               use.name == "execute_query" || use.name == Self.explainTool {
                artifact.runs.append(
                    QueryRun(
                        id: use.id,
                        sql: sql,
                        resultJSON: result.content,
                        isError: result.isError,
                        planText: use.name == Self.explainTool
                            ? Self.planText(fromResultJSON: result.content)
                            : nil
                    )
                )
            }
        }

        artifact.steps = Self.steps(uses: uses.map(\.block), results: results)
        return artifact
    }

    /// The statement a call would run. `confirm_destructive_operation` names its own key, and a call
    /// that carries neither is a read.
    internal static func statementText(from use: ToolUseBlock) -> String? {
        for key in ["query", "statement", "sql"] {
            if let text = ChatToolArgumentDecoder.optionalString(use.input, key: key),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    private static func state(for use: ToolUseBlock, result: ToolResultBlock?) -> ProposedStatementState {
        switch use.approvalState {
        case .pending:
            return .waiting
        case .cancelled:
            return .rejected
        case .denied(let reason):
            return .denied(reason: reason)
        case .approved:
            guard let result else { return .running }
            return result.isError ? .failed(message: result.content) : .ran
        }
    }

    /// One row per call, with consecutive reads folded together. A read is any call the pane does not
    /// treat as a statement, which keeps the fold honest as tools are added: a new read tool joins the
    /// group automatically, and a new write tool has to be named above to be listed at all.
    private static func steps(uses: [ToolUseBlock], results: [String: ToolResultBlock]) -> [AgentStep] {
        var steps: [AgentStep] = []
        var readRun: [ToolUseBlock] = []

        func flushReads() {
            guard !readRun.isEmpty else { return }
            let names = readRun.map(\.name)
            let unresolved = readRun.contains { results[$0.id] == nil }
            let failed = readRun.contains { results[$0.id]?.isError == true }
            steps.append(
                AgentStep(
                    id: readRun[0].id,
                    title: readRun.count == 1
                        ? Self.readTitle(readRun[0])
                        : String(
                            format: String(localized: "Read the schema (%d calls)"),
                            readRun.count
                        ),
                    detail: Set(names).sorted().joined(separator: ", "),
                    state: unresolved ? .inFlight : (failed ? .failed : .done)
                )
            )
            readRun.removeAll()
        }

        for use in uses {
            guard Self.statementTools.contains(use.name) else {
                readRun.append(use)
                continue
            }
            flushReads()
            let result = results[use.id]
            let state: AgentStep.State
            switch Self.state(for: use, result: result) {
            case .waiting:
                state = .waitingOnYou
            case .running:
                state = .inFlight
            case .ran:
                state = .done
            case .rejected, .denied, .failed:
                state = .failed
            }
            steps.append(
                AgentStep(
                    id: use.id,
                    title: Self.statementTitle(use),
                    detail: Self.statementText(from: use),
                    state: state
                )
            )
        }
        flushReads()
        return steps
    }

    private static func readTitle(_ use: ToolUseBlock) -> String {
        String(format: String(localized: "Called %@"), use.name)
    }

    private static func statementTitle(_ use: ToolUseBlock) -> String {
        use.name == "confirm_destructive_operation"
            ? String(localized: "Proposed a destructive statement")
            : String(localized: "Proposed a statement")
    }

    /// The engine's plan text, which the explain payload carries under `plan_text`. A payload without
    /// one is an engine whose plan TablePro could not flatten, and the raw rows are still in the
    /// result.
    internal static func planText(fromResultJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["plan_text"] as? String,
              !text.isEmpty
        else { return nil }
        return text
    }
}
