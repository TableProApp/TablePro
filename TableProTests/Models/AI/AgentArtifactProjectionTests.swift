//
//  AgentArtifactProjectionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AgentArtifactProjection", .serialized)
struct AgentArtifactProjectionTests {
    @MainActor
    private func transcript(_ blocks: [ChatContentBlock]) -> [ChatTurn] {
        [ChatTurn(role: .assistant, blocks: blocks)]
    }

    private func execute(_ sql: String, id: String, state: ToolApprovalState) -> ToolUseBlock {
        ToolUseBlock(
            id: id,
            name: "execute_query",
            input: .object(["query": .string(sql)]),
            approvalState: state
        )
    }

    @MainActor
    private func build(_ turns: [ChatTurn]) -> AgentArtifact {
        AgentArtifactProjection.build(from: turns, connectionName: "localhost", databaseType: .mysql)
    }

    @Test("A read-only session proposes no statements and still shows its steps")
    @MainActor
    func readOnlySessionHasStepsAndNoStatements() {
        let turns = transcript([
            .toolUse(ToolUseBlock(id: "a", name: "list_tables", input: .object([:]))),
            .toolResult(ToolResultBlock(toolUseId: "a", content: "{}"))
        ])

        let artifact = build(turns)

        #expect(artifact.statements.isEmpty)
        #expect(artifact.steps.count == 1)
        #expect(artifact.schemaChanges.isEmpty)
    }

    @Test("A waiting write is listed as waiting, with the connection it targets")
    @MainActor
    func waitingWriteIsListed() throws {
        let turns = transcript([
            .toolUse(execute("UPDATE users SET name = 'x' WHERE id = 1", id: "w1", state: .pending))
        ])

        let artifact = build(turns)
        let statement = try #require(artifact.statements.first)

        #expect(statement.state == .waiting)
        #expect(statement.awaitsDecision)
        #expect(statement.connectionName == "localhost")
        #expect(statement.tier == .write)
    }

    @Test("A rejected write stays in the list with its state")
    @MainActor
    func rejectedWriteStaysListed() throws {
        let turns = transcript([
            .toolUse(execute("DELETE FROM users WHERE id = 1", id: "w1", state: .cancelled)),
            .toolResult(ToolResultBlock(toolUseId: "w1", content: "User cancelled this tool call.", isError: true))
        ])

        let artifact = build(turns)
        let statement = try #require(artifact.statements.first)

        #expect(statement.state == .rejected)
        #expect(artifact.runs.isEmpty)
    }

    @Test("A denied write carries the reason it was denied")
    @MainActor
    func deniedWriteCarriesReason() throws {
        let turns = transcript([
            .toolUse(execute("UPDATE users SET name = 'x'", id: "w1", state: .denied(reason: "Read-only")))
        ])

        let statement = try #require(build(turns).statements.first)

        #expect(statement.state == .denied(reason: "Read-only"))
        #expect(statement.state.detail == "Read-only")
    }

    @Test("An approved write with no result yet is running")
    @MainActor
    func approvedWithNoResultIsRunning() throws {
        let turns = transcript([
            .toolUse(execute("UPDATE users SET name = 'x'", id: "w1", state: .approved))
        ])

        let statement = try #require(build(turns).statements.first)

        #expect(statement.state == .running)
    }

    @Test("A failed statement reports the engine's message")
    @MainActor
    func failedStatementReportsMessage() throws {
        let turns = transcript([
            .toolUse(execute("UPDATE nope SET name = 'x'", id: "w1", state: .approved)),
            .toolResult(ToolResultBlock(toolUseId: "w1", content: "no such table: nope", isError: true))
        ])

        let statement = try #require(build(turns).statements.first)

        #expect(statement.state == .failed(message: "no such table: nope"))
        #expect(build(turns).runs.isEmpty)
    }

    @Test("A completed query becomes a run with its rows and duration")
    @MainActor
    func completedQueryBecomesARun() throws {
        let payload = """
        {"columns":["id"],"rows":[["1"],["2"]],"row_count":2,"rows_affected":0,"execution_time_ms":12.5,\
        "is_truncated":false,"database":"db"}
        """
        let turns = transcript([
            .toolUse(execute("SELECT id FROM users", id: "r1", state: .approved)),
            .toolResult(ToolResultBlock(toolUseId: "r1", content: payload))
        ])

        let artifact = build(turns)
        let run = try #require(artifact.runs.first)
        let summary = try #require(QueryRunSummary.decode(run.resultJSON))

        #expect(summary.rowCount == 2)
        #expect(summary.durationMs == 12.5)
        #expect(summary.columns == ["id"])
        #expect(summary.rows == [["1"], ["2"]])
    }

    @Test("An explain result carries the plan text")
    @MainActor
    func explainRunCarriesPlanText() throws {
        let payload = """
        {"statement":"EXPLAIN SELECT 1","execution_time_ms":1.0,"columns":[],"rows":[],\
        "plan_text":"SCAN TABLE users"}
        """
        let turns = transcript([
            .toolUse(ToolUseBlock(
                id: "e1",
                name: "explain_query",
                input: .object(["query": .string("SELECT 1")])
            )),
            .toolResult(ToolResultBlock(toolUseId: "e1", content: payload))
        ])

        let run = try #require(build(turns).runs.first)

        #expect(run.planText == "SCAN TABLE users")
    }

    @Test("A query with no explain result has no plan text rather than an empty one")
    @MainActor
    func queryWithoutExplainHasNoPlan() throws {
        let turns = transcript([
            .toolUse(execute("SELECT 1", id: "r1", state: .approved)),
            .toolResult(ToolResultBlock(toolUseId: "r1", content: #"{"row_count":1}"#))
        ])

        let run = try #require(build(turns).runs.first)

        #expect(run.planText == nil)
    }

    @Test("A destructive statement is marked and previewed in the schema segment")
    @MainActor
    func destructiveStatementIsMarked() throws {
        let turns = transcript([
            .toolUse(ToolUseBlock(
                id: "d1",
                name: "confirm_destructive_operation",
                input: .object(["query": .string("DROP TABLE users")]),
                approvalState: .pending
            ))
        ])

        let artifact = build(turns)
        let statement = try #require(artifact.statements.first)
        let preview = try #require(artifact.schemaChanges.first)

        #expect(statement.isDestructive)
        #expect(preview.isDestructive)
        #expect(preview.lines.map(\.text) == ["TABLE users"])
    }

    @Test("Consecutive reads fold into one step")
    @MainActor
    func consecutiveReadsFold() throws {
        let turns = transcript([
            .toolUse(ToolUseBlock(id: "a", name: "list_tables", input: .object([:]))),
            .toolResult(ToolResultBlock(toolUseId: "a", content: "{}")),
            .toolUse(ToolUseBlock(id: "b", name: "describe_table", input: .object([:]))),
            .toolResult(ToolResultBlock(toolUseId: "b", content: "{}")),
            .toolUse(execute("SELECT 1", id: "c", state: .approved)),
            .toolResult(ToolResultBlock(toolUseId: "c", content: "{}"))
        ])

        let steps = build(turns).steps

        #expect(steps.count == 2)
        #expect(steps[0].detail == "describe_table, list_tables")
        #expect(steps[1].state == .done)
    }

    @Test("A waiting statement's step waits on you")
    @MainActor
    func waitingStatementStepWaitsOnYou() throws {
        let turns = transcript([
            .toolUse(execute("UPDATE users SET name = 'x'", id: "w1", state: .pending))
        ])

        let step = try #require(build(turns).steps.first)

        #expect(step.state == .waitingOnYou)
    }

    @Test("Statements from separate turns keep their transcript order")
    @MainActor
    func statementsKeepTranscriptOrder() {
        let turns = [
            ChatTurn(role: .assistant, blocks: [.toolUse(execute("SELECT 1", id: "a", state: .approved))]),
            ChatTurn(role: .user, blocks: [.toolResult(ToolResultBlock(toolUseId: "a", content: "{}"))]),
            ChatTurn(role: .assistant, blocks: [.toolUse(execute("SELECT 2", id: "b", state: .approved))]),
            ChatTurn(role: .user, blocks: [.toolResult(ToolResultBlock(toolUseId: "b", content: "{}"))])
        ]

        let artifact = build(turns)

        #expect(artifact.statements.map(\.id) == ["a", "b"])
    }

    @Test("An empty transcript projects an empty artifact")
    @MainActor
    func emptyTranscriptIsEmpty() {
        #expect(build([]).isEmpty)
    }

    @Test("A restored transcript projects the same artifact as a live one")
    @MainActor
    func restoredTranscriptProjectsTheSame() {
        let live = transcript([
            .toolUse(execute("UPDATE users SET name = 'x'", id: "w1", state: .approved)),
            .toolResult(ToolResultBlock(toolUseId: "w1", content: #"{"rows_affected":1}"#))
        ])
        let restored = live.map { ChatTurn(wire: $0.wireSnapshot) }

        #expect(build(live) == build(restored))
    }

    /// The pane rebuilds this on every render, twenty times a second while a reply streams, so the
    /// per-statement analysis is memoized. These cover what a memo can get wrong: an answer that
    /// changes when it should not, one statement's schema change appearing under another's id, and
    /// two engines sharing a verdict.

    @Test("Building the same transcript twice gives the same artifact")
    @MainActor
    func repeatedBuildsAgree() {
        let turns = transcript([
            .toolUse(execute("DROP TABLE orders", id: "d1", state: .approved)),
            .toolResult(ToolResultBlock(toolUseId: "d1", content: "{}")),
            .toolUse(execute("SELECT 1", id: "r1", state: .approved))
        ])

        #expect(build(turns) == build(turns))
        #expect(build(turns) == build(turns))
    }

    @Test("One statement proposed twice is listed under each call's own id")
    @MainActor
    func sameStatementKeepsPerCallIdentity() {
        let turns = transcript([
            .toolUse(execute("DROP TABLE orders", id: "first", state: .approved)),
            .toolResult(ToolResultBlock(toolUseId: "first", content: "{}")),
            .toolUse(execute("DROP TABLE orders", id: "second", state: .pending))
        ])

        let artifact = build(turns)

        #expect(artifact.statements.map(\.id) == ["first", "second"])
        #expect(artifact.schemaChanges.map(\.id) == ["first", "second"])
        #expect(artifact.statements.map(\.state) == [.ran, .waiting])
        /// Down to the lines. They are named after the change they belong to, so a memo that
        /// renamed only the preview would give both calls the same line ids.
        let lineIds = artifact.schemaChanges.flatMap { $0.lines.map(\.id) }
        #expect(!lineIds.isEmpty)
        #expect(Set(lineIds).count == lineIds.count)
        #expect(lineIds.allSatisfy { $0.hasPrefix("first.") || $0.hasPrefix("second.") })
    }

    @Test("The same statement on two engines is classified for each of them")
    @MainActor
    func analysisIsPerDatabaseType() {
        let turns = transcript([
            .toolUse(execute("CREATE TABLE t (id INT)", id: "c1", state: .approved))
        ])

        let mysql = AgentArtifactProjection.build(
            from: turns, connectionName: "localhost", databaseType: .mysql
        )
        let postgres = AgentArtifactProjection.build(
            from: turns, connectionName: "localhost", databaseType: .postgresql
        )

        #expect(mysql.schemaChanges.count == 1)
        #expect(postgres.schemaChanges.count == 1)
        #expect(mysql.statements.first?.tier == postgres.statements.first?.tier)
    }

    @Test("A statement's state still follows the call, not the memoized analysis")
    @MainActor
    func stateIsNotMemoized() throws {
        let waiting = transcript([
            .toolUse(execute("DELETE FROM users WHERE id = 1", id: "w1", state: .pending))
        ])
        #expect(try #require(build(waiting).statements.first).state == .waiting)

        let approved = transcript([
            .toolUse(execute("DELETE FROM users WHERE id = 1", id: "w1", state: .approved)),
            .toolResult(ToolResultBlock(toolUseId: "w1", content: #"{"rows_affected":1}"#))
        ])
        #expect(try #require(build(approved).statements.first).state == .ran)
    }
}
