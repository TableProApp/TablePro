import Foundation
import XCTest

final class HanaConnectionTests: XCTestCase {
    private static let configuration = HanaConnectConfiguration(
        host: "hana.example",
        port: 443,
        username: "DBADMIN",
        password: "test-only",
        schema: "APP",
        tlsMode: .verifyIdentity,
        tlsServerName: "",
        caCertificatePath: "",
        clientCertificatePath: "",
        clientKeyPath: "",
        connectTimeoutSeconds: 30
    )

    func testConnectOpensTheSessionFromTheConnectionQueueAndNotTheCaller() async throws {
        let bridge = HanaFakeBridge()
        let queue = HanaManualQueue()
        let connection = HanaConnection(bridge: bridge, queue: queue)
        let configuration = Self.configuration
        let connect = Task { try await connection.connect(configuration) }
        await queue.pending(reaching: 1)

        XCTAssertEqual(bridge.opens, 0)
        queue.runNext()
        await queue.pending(reaching: 1)

        XCTAssertEqual(bridge.opens, 1)
        XCTAssertTrue(bridge.connects.isEmpty)
        queue.runNext()
        let result = try await connect.value
        XCTAssertEqual(result.connectionId, 200_123)
        XCTAssertEqual(bridge.connects.count, 1)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testCancellingTheConnectWhileItsOpenWaitsInterruptsTheOpen() async throws {
        let bridge = HanaFakeBridge()
        let hold = bridge.holdOpen()
        let connection = HanaConnection(bridge: bridge)
        let configuration = Self.configuration
        let connect = Task { try await connection.connect(configuration) }
        let interruption = await hold.arrival()
        XCTAssertFalse(interruption.isInterrupted)

        connect.cancel()

        await assertFailure(of: connect, kind: .cancelled)
        XCTAssertTrue(interruption.isInterrupted)
        XCTAssertEqual(bridge.opens, 1)
        XCTAssertTrue(bridge.connects.isEmpty)
        XCTAssertTrue(bridge.closes.isEmpty)
    }

    func testAConnectCancelledBeforeItsOpenRunsHandsTheBridgeAnInterruptedOpen() async throws {
        let bridge = HanaFakeBridge()
        let queue = HanaManualQueue()
        let connection = HanaConnection(bridge: bridge, queue: queue)
        let configuration = Self.configuration
        let connect = Task { try await connection.connect(configuration) }
        await queue.pending(reaching: 1)

        connect.cancel()
        queue.runNext()

        await assertFailure(of: connect, kind: .cancelled)
        XCTAssertTrue(bridge.connects.isEmpty)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testAConnectAfterAnInterruptedOpenOpensNormally() async throws {
        let bridge = HanaFakeBridge()
        let hold = bridge.holdOpen()
        let connection = HanaConnection(bridge: bridge)
        let configuration = Self.configuration
        let cancelled = Task { try await connection.connect(configuration) }
        _ = await hold.arrival()
        cancelled.cancel()
        await assertFailure(of: cancelled, kind: .cancelled)
        let secondHold = bridge.holdOpen()
        let second = Task { try await connection.connect(configuration) }
        let secondOpen = await secondHold.arrival()
        secondHold.release()

        let result = try await second.value

        XCTAssertFalse(secondOpen.isInterrupted)
        XCTAssertEqual(result.connectionId, 200_123)
        XCTAssertEqual(bridge.connects.count, 1)
    }

    func testCancellingASlotThatNeverHeldAnOperationSendsNothing() async throws {
        let bridge = HanaFakeBridge()
        let connection = HanaConnection(bridge: bridge)

        connection.cancel(HanaOperationSlot())
        _ = try await connection.connect(Self.configuration)
        _ = try await connection.execute("SELECT 1 FROM DUMMY")
        connection.cancel(HanaOperationSlot())

        XCTAssertTrue(bridge.cancels.isEmpty)
    }

    func testASlotCancelledBeforeItsQueryIsEnqueuedKeepsTheQueryOffTheBridge() async throws {
        let bridge = HanaFakeBridge()
        let connection = HanaConnection(bridge: bridge)
        _ = try await connection.connect(Self.configuration)
        let slot = HanaOperationSlot()

        connection.cancel(slot)

        do {
            _ = try await connection.execute("DELETE FROM T", cancellation: slot)
            XCTFail("a query whose slot was already cancelled should not run")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertTrue(bridge.statements.isEmpty)
        XCTAssertTrue(bridge.cancels.isEmpty)
    }

    func testCancellingAQueryQueuedBehindAPingStopsTheQueryAndLeavesThePingAlone() async throws {
        let bridge = HanaFakeBridge()
        let queue = HanaRecordingQueue()
        let connection = HanaConnection(bridge: bridge, queue: queue)
        _ = try await connection.connect(Self.configuration)
        let pingHold = bridge.holdPing()
        let ping = Task { try await connection.ping() }
        let pingTicket = await pingHold.arrival()
        let slot = HanaOperationSlot()
        let query = Task { try await connection.execute("SELECT * FROM BIG", cancellation: slot) }
        await queue.submissions(reaching: 4)

        connection.cancel(slot)

        let queryTicket = HanaOperationTicket(session: pingTicket.session, operation: pingTicket.operation + 1)
        XCTAssertEqual(bridge.cancels, [queryTicket])
        pingHold.release()
        try await ping.value
        do {
            _ = try await query.value
            XCTFail("the query queued behind the ping should not run")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(bridge.pings, [pingTicket])
        XCTAssertTrue(bridge.statements.isEmpty)
    }

    func testAStopThatLandsAfterItsOperationFinishedNeverCancelsTheNextOne() async throws {
        let bridge = HanaFakeBridge()
        let connection = HanaConnection(bridge: bridge)
        _ = try await connection.connect(Self.configuration)
        let first = bridge.hold(sql: "UPDATE A SET X = 1")
        let second = bridge.hold(sql: "UPDATE B SET X = 1")
        let delivery = bridge.holdCancels()
        let firstSlot = HanaOperationSlot()
        let firstRun = Task { try await connection.execute("UPDATE A SET X = 1", cancellation: firstSlot) }
        let firstTicket = await first.arrival()

        let stopReturned = HanaLatch()
        DispatchQueue.global().async {
            connection.cancel(firstSlot)
            stopReturned.open()
        }
        let stoppedTicket = await delivery.arrival()
        first.release()
        _ = try await firstRun.value
        let secondRun = Task { try await connection.execute("UPDATE B SET X = 1") }
        let secondTicket = await second.arrival()
        delivery.release()
        await stopReturned.wait()
        second.release()

        _ = try await secondRun.value
        XCTAssertEqual(stoppedTicket, firstTicket)
        XCTAssertNotEqual(secondTicket, firstTicket)
        XCTAssertEqual(bridge.cancels, [firstTicket])
    }

    func testAStopWhileAnOperationRunsNamesExactlyThatOperation() async throws {
        let bridge = HanaFakeBridge()
        let connection = HanaConnection(bridge: bridge)
        _ = try await connection.connect(Self.configuration)
        let hold = bridge.hold(sql: "SELECT * FROM BIG")
        let slot = HanaOperationSlot()
        let run = Task { try await connection.execute("SELECT * FROM BIG", cancellation: slot) }
        let ticket = await hold.arrival()

        connection.cancel(slot)

        XCTAssertEqual(bridge.cancels, [ticket])
        XCTAssertNotEqual(ticket.operation, 0)
        hold.release()
        await assertFailure(of: run, kind: .cancelled)
    }

    func testCancellingASlotAgainAfterItsOperationFinishedSendsNothingNew() async throws {
        let bridge = HanaFakeBridge()
        let connection = HanaConnection(bridge: bridge)
        _ = try await connection.connect(Self.configuration)
        let hold = bridge.hold(sql: "SELECT * FROM BIG")
        let slot = HanaOperationSlot()
        let run = Task { try await connection.execute("SELECT * FROM BIG", cancellation: slot) }
        let ticket = await hold.arrival()
        connection.cancel(slot)
        XCTAssertEqual(bridge.cancels, [ticket])
        hold.release()
        await assertFailure(of: run, kind: .cancelled)

        connection.cancel(slot)

        XCTAssertEqual(bridge.cancels, [ticket])
        _ = try await connection.execute("SELECT 1 FROM DUMMY")
        XCTAssertEqual(bridge.statements.map(\.sql), ["SELECT * FROM BIG", "SELECT 1 FROM DUMMY"])
    }

    func testCancellingTheTaskStopsItsOwnOperationBeforeCancelReturns() async throws {
        let bridge = HanaFakeBridge()
        let connection = HanaConnection(bridge: bridge)
        _ = try await connection.connect(Self.configuration)
        let hold = bridge.hold(sql: "SELECT * FROM BIG")
        let run = Task { try await connection.execute("SELECT * FROM BIG") }
        let ticket = await hold.arrival()

        run.cancel()

        XCTAssertEqual(bridge.cancels, [ticket])
        hold.release()
        await assertFailure(of: run, kind: .cancelled)
        XCTAssertEqual(bridge.cancels, [ticket])
    }

    func testATaskCancelledWhileQueuedNeverReachesTheBridge() async throws {
        let bridge = HanaFakeBridge()
        let queue = HanaRecordingQueue()
        let connection = HanaConnection(bridge: bridge, queue: queue)
        _ = try await connection.connect(Self.configuration)
        let hold = bridge.hold(sql: "SELECT * FROM BIG")
        let running = Task { try await connection.execute("SELECT * FROM BIG") }
        _ = await hold.arrival()
        let queued = Task { try await connection.execute("DELETE FROM T") }
        await queue.submissions(reaching: 4)

        queued.cancel()
        hold.release()

        _ = try await running.value
        do {
            _ = try await queued.value
            XCTFail("the queued statement should not run")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(bridge.statements.map(\.sql), ["SELECT * FROM BIG"])
    }

    func testDisconnectClosesTheSessionBeforeReturningAndDropsQueuedWork() async throws {
        let bridge = HanaFakeBridge()
        let queue = HanaRecordingQueue()
        let connection = HanaConnection(bridge: bridge, queue: queue)
        _ = try await connection.connect(Self.configuration)
        let hold = bridge.hold(sql: "UPDATE A SET X = 1")
        let running = Task { try await connection.execute("UPDATE A SET X = 1") }
        let runningTicket = await hold.arrival()
        let queued = Task { try await connection.execute("DELETE FROM T") }
        await queue.submissions(reaching: 4)

        connection.disconnect()

        XCTAssertEqual(bridge.closes, [runningTicket.session])
        hold.release()
        await assertFailure(of: running, kind: .closed)
        await assertFailure(of: queued, kind: .closed)
        XCTAssertEqual(bridge.statements.map(\.sql), ["UPDATE A SET X = 1"])
        XCTAssertFalse(connection.hasLostConnection)
    }

    func testReconnectClosesTheOldSessionAndDropsWorkQueuedForIt() async throws {
        let bridge = HanaFakeBridge()
        let queue = HanaRecordingQueue()
        let connection = HanaConnection(bridge: bridge, queue: queue)
        _ = try await connection.connect(Self.configuration)
        let hold = bridge.hold(sql: "UPDATE A SET X = 1")
        let running = Task { try await connection.execute("UPDATE A SET X = 1") }
        let oldSession = await hold.arrival().session
        let queued = Task { try await connection.execute("DELETE FROM T") }
        await queue.submissions(reaching: 4)

        let configuration = Self.configuration
        let reconnect = Task { try await connection.connect(configuration) }
        await queue.submissions(reaching: 5)

        XCTAssertEqual(bridge.closes, [oldSession])
        hold.release()
        await assertFailure(of: queued, kind: .closed)
        _ = try await reconnect.value
        _ = try? await running.value
        XCTAssertEqual(bridge.statements.map(\.sql), ["UPDATE A SET X = 1"])
        XCTAssertEqual(bridge.connects.map(\.session), [oldSession, oldSession + 1])
        _ = try await connection.execute("SELECT 1 FROM DUMMY")
        XCTAssertEqual(bridge.statements.last?.ticket.session, oldSession + 1)
    }

    func testASessionLostEnvelopeKeepsItsRowsAndMarksTheConnectionLost() async throws {
        let bridge = HanaFakeBridge()
        bridge.respond(to: "COMMIT", with: HanaBridgeJSON.envelope(columns: ["A"], rows: [["1"]], sessionLost: true))
        let connection = HanaConnection(bridge: bridge)
        _ = try await connection.connect(Self.configuration)

        _ = try await connection.execute("SELECT 1 FROM DUMMY")
        XCTAssertFalse(connection.hasLostConnection)
        let envelope = try await connection.execute("COMMIT")

        XCTAssertEqual(envelope.rows, [[.text("1")]])
        XCTAssertTrue(envelope.sessionLost)
        XCTAssertTrue(connection.hasLostConnection)
    }

    func testAPlanFromASessionLostWhileDiscardingItStillArrives() async throws {
        let bridge = HanaFakeBridge()
        let plan = HanaBridgeJSON.envelope(columns: ["QUERY PLAN"], rows: [["COLUMN SEARCH"]], sessionLost: true)
        bridge.respond(to: "SELECT * FROM T", with: plan)
        let connection = HanaConnection(bridge: bridge)
        _ = try await connection.connect(Self.configuration)

        let envelope = try await connection.explain(sql: "SELECT * FROM T", cancellation: HanaOperationSlot())

        XCTAssertEqual(envelope.rows, [[.text("COLUMN SEARCH")]])
        XCTAssertTrue(connection.hasLostConnection)
    }

    func testReconnectingClearsALostSession() async throws {
        let bridge = HanaFakeBridge()
        bridge.respond(to: "COMMIT", with: HanaBridgeJSON.envelope(sessionLost: true))
        let connection = HanaConnection(bridge: bridge)
        _ = try await connection.connect(Self.configuration)
        _ = try await connection.execute("COMMIT")
        XCTAssertTrue(connection.hasLostConnection)

        _ = try await connection.connect(Self.configuration)

        XCTAssertFalse(connection.hasLostConnection)
    }

    private func assertFailure<T: Sendable>(
        of task: Task<T, any Error>,
        kind: HanaBridgeFailure.Kind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("the operation should fail with \(kind)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? HanaBridgeFailure)?.kind, kind, "got \(error)", file: file, line: line)
        }
    }
}

private extension HanaConnection {
    func execute(
        _ sql: String,
        cancellation: HanaOperationSlot = HanaOperationSlot()
    ) async throws -> HanaResultEnvelope {
        try await execute(sql: sql, parameters: nil, rowCap: 0, cancellation: cancellation)
    }
}
