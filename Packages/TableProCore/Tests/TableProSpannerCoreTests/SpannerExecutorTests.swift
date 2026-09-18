import Foundation
@testable import TableProSpannerCore
import Testing

@Suite("Spanner executor EXPLAIN")
struct SpannerExecutorExplainTests {
    @Test("EXPLAIN DELETE plans in a throwaway transaction, rolls it back and never commits")
    func explainDeleteNeverCommits() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        let outcome = try await executor.run("EXPLAIN DELETE FROM Singers WHERE TRUE", hostParameters: nil)

        let plans = server.calls(verb: "executeSql")
        #expect(plans.count == 1)
        #expect(plans.first?.queryMode == "PLAN")
        #expect(plans.first?.transaction == "begin")
        #expect(plans.first?.seqno == "1")
        #expect(plans.first?.sql == "DELETE FROM Singers WHERE TRUE")
        #expect(server.calls(verb: "rollback").count == 1)
        #expect(server.calls(verb: "commit").isEmpty)
        #expect(outcome.fields.map(\.name) == [SpannerPlanRenderer.columnName])
        #expect(outcome.rows == [[.text("Distributed Union")]])
    }

    @Test("EXPLAIN of DML inside an open transaction uses its id and the next seqno")
    func explainInsideTransaction() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        try await executor.beginTransaction()
        _ = try await executor.run("UPDATE Singers SET Age = 1 WHERE Id = 1", hostParameters: nil)
        _ = try await executor.run("EXPLAIN UPDATE Singers SET Age = 2 WHERE Id = 1", hostParameters: nil)

        let calls = server.calls(verb: "executeSql")
        #expect(calls.map(\.transaction) == ["tx1", "tx1"])
        #expect(calls.map(\.seqno) == ["1", "2"])
        #expect(calls.last?.queryMode == "PLAN")
        #expect(server.calls(verb: "rollback").isEmpty)
    }

    @Test("EXPLAIN of DDL or transaction control is refused before any request")
    func explainDDLRefused() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        for sql in ["EXPLAIN DROP TABLE Singers", "EXPLAIN CREATE INDEX i ON t(c)", "EXPLAIN BEGIN", "EXPLAIN COMMIT"] {
            await #expect(throws: SpannerExecutionError.self) {
                _ = try await executor.run(sql, hostParameters: nil)
            }
        }
        #expect(server.recorded.isEmpty)
    }

    @Test("EXPLAIN ANALYZE is refused because it would run the statement")
    func explainAnalyzeRefused() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        await #expect(throws: SpannerExecutionError.explainAnalyzeNotSupported) {
            _ = try await executor.run("EXPLAIN ANALYZE DELETE FROM Singers WHERE TRUE", hostParameters: nil)
        }
        #expect(server.recorded.isEmpty)
    }

    @Test("EXPLAIN of a query plans on the read session with a single-use read")
    func explainQuery() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        _ = try await executor.run("-- note\nEXPLAIN SELECT * FROM Singers", hostParameters: nil)

        let call = try #require(server.calls(verb: "executeSql").first)
        #expect(call.queryMode == "PLAN")
        #expect(call.transaction == "singleUse")
        #expect(call.seqno == nil)
    }
}

@Suite("Spanner executor transactions")
struct SpannerExecutorTransactionTests {
    @Test("BEGIN twice is refused")
    func beginTwice() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        _ = try await executor.run("BEGIN", hostParameters: nil)
        await #expect(throws: SpannerExecutionError.transactionAlreadyOpen) {
            try await executor.beginTransaction()
        }
        #expect(server.calls(verb: "beginTransaction").count == 1)
    }

    @Test("COMMIT without a transaction throws and ROLLBACK is a no-op")
    func commitWithoutTransaction() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        await #expect(throws: SpannerExecutionError.noTransactionOpen) {
            _ = try await executor.run("COMMIT", hostParameters: nil)
        }
        _ = try await executor.run("ROLLBACK", hostParameters: nil)
        #expect(server.recorded.isEmpty)
    }

    @Test("A failed COMMIT leaves no transaction behind")
    func failedCommitLeavesIdle() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)
        server.failNext("commit", with: .json(#"{"error":{"code":500,"status":"INTERNAL","message":"boom"}}"#, status: 500))

        try await executor.beginTransaction()
        _ = try await executor.run("UPDATE Singers SET Age = 1 WHERE Id = 1", hostParameters: nil)
        await #expect(throws: SpannerAPIError.self) {
            try await executor.commitTransaction()
        }
        #expect(await executor.hasOpenTransaction == false)

        _ = try await executor.run("UPDATE Singers SET Age = 2 WHERE Id = 1", hostParameters: nil)
        #expect(server.calls(verb: "executeSql").last?.transaction == "begin")
    }

    @Test("ABORTED inside a transaction refuses later statements until ROLLBACK")
    func abortedRefusesUntilRollback() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)
        server.failNext("executeSql", with: .json(SpannerFakeServer.abortedBody, status: 409))

        try await executor.beginTransaction()
        await #expect(throws: SpannerAPIError.self) {
            _ = try await executor.run("UPDATE Singers SET Age = 1 WHERE Id = 1", hostParameters: nil)
        }
        await #expect(throws: SpannerExecutionError.transactionAborted) {
            _ = try await executor.run("UPDATE Singers SET Age = 2 WHERE Id = 1", hostParameters: nil)
        }
        await #expect(throws: SpannerExecutionError.transactionAborted) {
            try await executor.commitTransaction()
        }
        try await executor.rollbackTransaction()
        _ = try await executor.run("UPDATE Singers SET Age = 3 WHERE Id = 1", hostParameters: nil)
        #expect(server.calls(verb: "executeSql").last?.transaction == "begin")
    }

    @Test("Autocommit DML retries the whole unit when the commit is aborted")
    func autocommitRetriesAborted() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)
        server.failNext("commit", with: .json(SpannerFakeServer.abortedBody, status: 409))

        let outcome = try await executor.run("DELETE FROM Singers WHERE Id = 1", hostParameters: nil)

        #expect(outcome.rowsAffected == 3)
        #expect(server.calls(verb: "commit").count == 2)
        #expect(server.calls(verb: "executeSql").count == 2)
    }

    @Test("Concurrent statements in a transaction get strictly increasing seqnos in send order")
    func seqnosStayOrdered() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)
        try await executor.beginTransaction()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try await executor.run("UPDATE Singers SET Age = \(index) WHERE Id = 1", hostParameters: nil)
                }
            }
            try await group.waitForAll()
        }

        let seqnos = server.calls(verb: "executeSql").compactMap { $0.seqno.flatMap(Int.init) }
        #expect(seqnos == Array(1...20))
    }

    @Test("BEGIN retries on a new session when the leased one was deleted")
    func beginRetriesLostSession() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)
        server.failNext("beginTransaction", with: .json(SpannerFakeServer.sessionNotFoundBody, status: 404))

        try await executor.beginTransaction()

        #expect(server.calls(verb: "beginTransaction").count == 2)
        #expect(server.calls(verb: "createSession").count == 2)
        #expect(await executor.hasOpenTransaction)
    }
}

@Suite("Spanner executor reads and parameters")
struct SpannerExecutorReadTests {
    @Test("A read recreates the read session once when the server deleted it")
    func readSessionRecreated() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)
        server.failNext("executeStreamingSql", with: .json(SpannerFakeServer.sessionNotFoundBody, status: 404))

        let outcome = try await executor.run("SELECT v FROM t", hostParameters: nil)

        #expect(outcome.rows == [[.text("1")]])
        #expect(server.calls(verb: "createSession").count == 2)
        #expect(server.calls(verb: "executeStreamingSql").count == 2)
    }

    @Test("Parameter types are discovered once per statement text and always sent")
    func discoveryIsMemoized() async throws {
        let server = SpannerFakeServer()
        server.undeclaredParameters = [("p1", "INT64")]
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        for _ in 0..<2 {
            _ = try await executor.run("SELECT v FROM t WHERE v = ?", hostParameters: [.text("1")])
        }

        let plans = server.calls(verb: "executeSql").filter { $0.queryMode == "PLAN" }
        #expect(plans.count == 1)
        let reads = server.calls(verb: "executeStreamingSql")
        #expect(reads.count == 2)
        #expect(reads.allSatisfy { $0.paramTypeCodes == ["p1": "INT64"] && $0.sql == "SELECT v FROM t WHERE v = @p1" })
    }

    @Test("A schema change clears the parameter types learned before it")
    func ddlClearsMemo() async throws {
        let server = SpannerFakeServer()
        server.undeclaredParameters = [("p1", "INT64")]
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        _ = try await executor.run("SELECT v FROM t WHERE v = ?", hostParameters: [.text("1")])
        _ = try await executor.run("ALTER TABLE t ADD COLUMN w INT64", hostParameters: nil)
        _ = try await executor.run("SELECT v FROM t WHERE v = ?", hostParameters: [.text("1")])

        #expect(server.calls(verb: "executeSql").filter { $0.queryMode == "PLAN" }.count == 2)
    }

    @Test("Autocommit DML with parameters discovers types inside the transaction it commits")
    func autocommitDiscovery() async throws {
        let server = SpannerFakeServer()
        server.undeclaredParameters = [("p1", "BOOL"), ("p2", "INT64")]
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        _ = try await executor.run(
            "UPDATE Singers SET Active = ? WHERE Id = ?",
            hostParameters: [.text("true"), .text("5")]
        )

        let calls = server.calls(verb: "executeSql")
        #expect(calls.map(\.queryMode) == ["PLAN", "NORMAL"])
        #expect(calls.map(\.transaction) == ["begin", "tx1"])
        #expect(calls.map(\.seqno) == ["1", "2"])
        #expect(calls.last?.paramTypeCodes == ["p1": "BOOL", "p2": "INT64"])
        #expect(server.calls(verb: "commit").count == 1)
    }

    @Test("A placeholder count that does not match the values is refused")
    func placeholderMismatch() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        await #expect(throws: SpannerExecutionError.parameterCount(found: 2, expected: 1)) {
            _ = try await executor.run("SELECT ? , ?", hostParameters: [.text("1")])
        }
        #expect(server.recorded.isEmpty)
    }

    @Test("Streaming a statement that is not a query runs it and emits an empty header")
    func streamNonQuery() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        var outputs: [SpannerStreamOutput] = []
        for try await output in executor.stream("DELETE FROM Singers WHERE Id = 1", hostParameters: nil) {
            outputs.append(output)
        }
        #expect(outputs == [.header([])])
        #expect(server.calls(verb: "commit").count == 1)
    }
}

@Suite("Spanner executor schema changes and shutdown")
struct SpannerExecutorLifecycleTests {
    @Test("A schema change past its deadline reports it is still running")
    func ddlDeadline() async throws {
        let server = SpannerFakeServer()
        server.operationNeverFinishes = true
        let (executor, _) = try SpannerTestFixtures.executor(server: server, ddlDeadline: { .milliseconds(20) })

        await #expect(throws: SpannerExecutionError.self) {
            _ = try await executor.run("CREATE INDEX i ON t(c)", hostParameters: nil)
        }
    }

    @Test("Without a deadline the schema change is polled until done")
    func ddlWithoutDeadline() async throws {
        let server = SpannerFakeServer()
        server.operationPollsUntilDone = 3
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        _ = try await executor.run("CREATE INDEX i ON t(c)", hostParameters: nil)

        #expect(server.calls(verb: "operation").count == 3)
    }

    @Test("Shutdown deletes regular sessions, keeps the multiplexed one, closes the client, then refuses work")
    func shutdownOrder() async throws {
        let server = SpannerFakeServer()
        let (executor, transport) = try SpannerTestFixtures.executor(server: server)
        _ = try await executor.run("SELECT 1", hostParameters: nil)
        _ = try await executor.run("DELETE FROM t WHERE TRUE", hostParameters: nil)

        await executor.shutdown()
        await executor.shutdown()

        let deletes = server.calls(verb: "deleteSession")
        #expect(deletes.count == 1)
        #expect(deletes.first?.path.hasSuffix("/sessions/s2") == true)
        #expect(transport.closeCount == 1)
        await #expect(throws: SpannerExecutionError.closed) {
            _ = try await executor.run("SELECT 1", hostParameters: nil)
        }
    }
}

@Suite("Spanner executor transaction ownership and unknown outcomes")
struct SpannerExecutorOwnershipTests {
    @Test("A grid save during an editor BEGIN is refused and its rollback leaves the editor transaction open")
    func hostCannotEndEditorTransaction() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        _ = try await executor.run("BEGIN", hostParameters: nil)
        _ = try await executor.run("DELETE FROM Singers WHERE Id = 1", hostParameters: nil)
        await #expect(throws: SpannerExecutionError.transactionAlreadyOpen) {
            try await executor.beginTransaction()
        }
        try await executor.rollbackTransaction()
        await #expect(throws: SpannerExecutionError.noTransactionOpen) {
            try await executor.commitTransaction()
        }

        #expect(await executor.hasOpenTransaction)
        #expect(server.calls(verb: "rollback").isEmpty)
        _ = try await executor.run("COMMIT", hostParameters: nil)
        #expect(server.calls(verb: "commit").count == 1)
    }

    @Test("An editor ROLLBACK can end a transaction the host began")
    func statementEndsHostTransaction() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)

        try await executor.beginTransaction()
        _ = try await executor.run("ROLLBACK", hostParameters: nil)

        #expect(await executor.hasOpenTransaction == false)
        #expect(server.calls(verb: "rollback").count == 1)
    }

    @Test("A commit lost in transit reports an unknown outcome, and the rollback after it does not claim success")
    func commitOutcomeUnknown() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)
        server.failNext("commit", with: .failing(.timedOut))
        server.failNext("commit", with: .failing(.timedOut))
        server.failNext("commit", with: .failing(.timedOut))
        server.failNext("commit", with: .failing(.timedOut))

        try await executor.beginTransaction()
        _ = try await executor.run("UPDATE Singers SET Age = 1 WHERE Id = 1", hostParameters: nil)
        await #expect(throws: SpannerExecutionError.commitOutcomeUnknown) {
            try await executor.commitTransaction()
        }
        await #expect(throws: SpannerExecutionError.commitOutcomeUnknown) {
            try await executor.rollbackTransaction()
        }
        try await executor.rollbackTransaction()
        #expect(await executor.hasOpenTransaction == false)
    }

    @Test("A DML statement that times out inside a transaction aborts it, so COMMIT cannot save an unknown result")
    func timedOutStatementAborts() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)
        for _ in 0..<4 {
            server.failNext("executeSql", with: .failing(.timedOut))
        }

        try await executor.beginTransaction()
        await #expect(throws: SpannerTransportError.timedOut) {
            _ = try await executor.run("UPDATE Singers SET Age = 1 WHERE Id = 1", hostParameters: nil)
        }
        await #expect(throws: SpannerExecutionError.transactionAborted) {
            try await executor.commitTransaction()
        }
        #expect(server.calls(verb: "commit").isEmpty)
    }

    @Test("A lost pooled session discards every idle session so the retry runs on a new one")
    func expiredPoolIsDropped() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)
        async let first = executor.run("DELETE FROM a WHERE TRUE", hostParameters: nil)
        async let second = executor.run("DELETE FROM b WHERE TRUE", hostParameters: nil)
        _ = try await (first, second)
        let createdBefore = server.calls(verb: "createSession").count
        server.failNext("executeSql", with: .json(SpannerFakeServer.sessionNotFoundBody, status: 404))

        _ = try await executor.run("DELETE FROM c WHERE TRUE", hostParameters: nil)

        #expect(server.calls(verb: "createSession").count == createdBefore + 1)
    }

    @Test("Cancelling a read does not turn it into a successful partial result")
    func cancelledReadThrows() async throws {
        let server = SpannerFakeServer()
        let (executor, _) = try SpannerTestFixtures.executor(server: server)
        let task = Task {
            try await Task.sleep(for: .milliseconds(50))
            return try await executor.run("SELECT v FROM t", hostParameters: nil)
        }
        task.cancel()
        await #expect(throws: (any Error).self) {
            _ = try await task.value
        }
    }
}
