import Darwin
import Foundation
import TableProPluginKit
import XCTest

final class HanaHelperBridgeTests: XCTestCase {
    private static let missingHelper = """
        tablepro-hana-helper is missing from the test bundle's Contents/MacOS. \
        Run scripts/build-hana.sh, then build HanaDriverTests again.
        """
    private static let callDeadline: TimeInterval = 30
    private static let foreignTeam = "ABCDE12345"
    private static let developmentHost = HanaHelperTrust(signingTeam: nil, admitsUnsignedHost: true)

    private var bundledHelper: URL?
    private var bridges: [HanaHelperBridge] = []
    private var servers: [HanaSilentServer] = []
    private var folder: HanaStandInFolder?

    override func setUpWithError() throws {
        let helper = Bundle(for: HanaPluginDriver.self).url(forAuxiliaryExecutable: HanaHelperTrust.executableName)
        bundledHelper = try XCTUnwrap(helper, Self.missingHelper)
        folder = try HanaStandInFolder(named: "HanaHelperBridgeTests")
    }

    override func tearDown() {
        bridges.forEach { $0.shutdown() }
        bridges.removeAll()
        servers.forEach { $0.stop() }
        servers.removeAll()
        folder?.remove()
        super.tearDown()
    }

    func testOpeningTheFirstSessionStartsAHelperThatPassesTheHandshake() throws {
        let bridge = makeBridge()

        let session = try open(on: bridge, port: HanaLoopbackSocket.closedPort())

        XCTAssertGreaterThan(session, 0)
        let processIdentifier = try XCTUnwrap(bridge.helperProcessIdentifier(serving: session))
        XCTAssertTrue(HanaProcessProbe.isRunning(processIdentifier))
    }

    func testTheBundledHelperAnnouncesTheBridgesForcedSeverGrace() throws {
        let launched = try HanaHelperProcess.launch(executable: XCTUnwrap(bundledHelper), handshakeDeadline: Self.callDeadline)
        defer { launched.process.shutdown() }

        XCTAssertEqual(launched.greeting, HanaHelperGreeting(forcedSeverGrace: 30))
        XCTAssertEqual(HanaHelperBridge.cancelDeadline(forcedSeverGrace: launched.greeting.forcedSeverGrace), 40)
    }

    func testEverySessionHasItsOwnHelperAndClosingOneLeavesTheOtherServing() throws {
        let bridge = makeBridge()
        let port = try HanaLoopbackSocket.closedPort()
        let first = try open(on: bridge, port: port)
        let second = try open(on: bridge, port: port)
        let firstHelper = try XCTUnwrap(bridge.helperProcessIdentifier(serving: first))
        let secondHelper = try XCTUnwrap(bridge.helperProcessIdentifier(serving: second))

        bridge.close(session: first)

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(firstHelper, secondHelper)
        XCTAssertTrue(HanaProcessProbe.waitForExit(of: firstHelper, within: Self.callDeadline))
        XCTAssertTrue(HanaProcessProbe.isRunning(secondHelper))
        XCTAssertThrowsError(try bridge.connect(HanaOperationTicket(session: second, operation: 1))) { error in
            XCTAssertEqual((error as? HanaBridgeFailure)?.kind, .connect, "got \(error)")
        }
    }

    func testAnOpenTheHelperRefusesShutsThatHelperDown() throws {
        let recordedIdentifier = try standInFile("pid")
        let standIn = try standIn("""
            echo $$ > '\(recordedIdentifier.path)'
            \(HanaStandInFrame.greeting())
            /usr/bin/head -c 13 > /dev/null
            \(HanaStandInFrame.frame(id: 1, code: 1, body: #"{"kind":"configuration","message":"host"}"#))
            \(HanaStandInFrame.absorbInput())
            """)
        let bridge = makeBridge(trust: Self.developmentHost, locateExecutable: { standIn })

        XCTAssertThrowsError(try open(on: bridge, port: 30_015)) { error in
            XCTAssertEqual((error as? HanaBridgeFailure)?.kind, .configuration, "got \(error)")
        }

        let processIdentifier = try XCTUnwrap(HanaFileProbe.processIdentifier(recordedAt: recordedIdentifier, within: 1))
        XCTAssertTrue(HanaProcessProbe.waitForExit(of: processIdentifier, within: Self.callDeadline))
    }

    func testOpeningWithAnInvalidConfigurationIsAConfigurationFailure() throws {
        let bridge = makeBridge()

        XCTAssertThrowsError(try bridge.open(configuration: configuration(host: "", port: 30_015), interruption: HanaOpenInterruption())) { error in
            let failure = error as? HanaBridgeFailure
            XCTAssertEqual(failure?.kind, .configuration, "got \(error)")
            XCTAssertEqual(failure?.message, "host")
        }
    }

    func testConnectingToAClosedPortIsAConnectFailure() throws {
        let bridge = makeBridge()
        let session = try open(on: bridge, port: HanaLoopbackSocket.closedPort())

        XCTAssertThrowsError(try bridge.connect(HanaOperationTicket(session: session, operation: 1))) { error in
            XCTAssertEqual((error as? HanaBridgeFailure)?.kind, .connect, "got \(error)")
        }
    }

    func testCancellingAConnectTheServerNeverAnswersReportsCancelled() throws {
        let bridge = makeBridge()
        let (ticket, call) = try blockedConnect(on: bridge)

        bridge.cancel(ticket)

        XCTAssertEqual(try failure(of: call).kind, .cancelled)
        let processIdentifier = try XCTUnwrap(bridge.helperProcessIdentifier(serving: ticket.session))
        XCTAssertTrue(HanaProcessProbe.isRunning(processIdentifier))
    }

    func testKillingTheHelperFailsThePendingCallAsConnectionLostAndLaterCallsFailCleanly() throws {
        let bridge = makeBridge()
        let (ticket, call) = try blockedConnect(on: bridge)
        let processIdentifier = try XCTUnwrap(bridge.helperProcessIdentifier(serving: ticket.session))

        kill(processIdentifier, SIGKILL)
        for _ in 0..<200 {
            bridge.cancel(ticket)
        }

        let lost = try failure(of: call)
        XCTAssertEqual(lost.kind, .connectionLost)
        XCTAssertTrue(lost.message.contains("signal \(SIGKILL)"), lost.message)
        XCTAssertThrowsError(try bridge.ping(HanaOperationTicket(session: ticket.session, operation: 2))) { error in
            XCTAssertEqual((error as? HanaBridgeFailure)?.kind, .connectionLost, "got \(error)")
        }
        XCTAssertThrowsError(try bridge.connect(HanaOperationTicket(session: ticket.session, operation: 3))) { error in
            XCTAssertEqual((error as? HanaBridgeFailure)?.kind, .connectionLost, "got \(error)")
        }
        bridge.close(session: ticket.session)
        XCTAssertTrue(HanaProcessProbe.waitForExit(of: processIdentifier, within: Self.callDeadline))
    }

    func testOpeningAfterTheHelperDiedStartsANewHelper() throws {
        let bridge = makeBridge()
        let (ticket, call) = try blockedConnect(on: bridge)
        let firstHelper = try XCTUnwrap(bridge.helperProcessIdentifier(serving: ticket.session))
        kill(firstHelper, SIGKILL)
        XCTAssertEqual(try failure(of: call).kind, .connectionLost)

        let session = try open(on: bridge, port: HanaLoopbackSocket.closedPort())

        let secondHelper = try XCTUnwrap(bridge.helperProcessIdentifier(serving: session))
        XCTAssertNotEqual(secondHelper, firstHelper)
        XCTAssertThrowsError(try bridge.connect(HanaOperationTicket(session: session, operation: 1))) { error in
            XCTAssertEqual((error as? HanaBridgeFailure)?.kind, .connect, "got \(error)")
        }
    }

    func testACancelledCallTheHelperNeverAnswersEndsTheHelperAtTheDeadline() throws {
        let bridge = makeBridge(cancelDeadline: 1)
        let (ticket, call) = try blockedConnect(on: bridge)
        let processIdentifier = try XCTUnwrap(bridge.helperProcessIdentifier(serving: ticket.session))
        kill(processIdentifier, SIGSTOP)

        bridge.cancel(ticket)

        let lost = try failure(of: call)
        XCTAssertEqual(lost.kind, .connectionLost)
        XCTAssertTrue(lost.message.contains("cancelled operation"), lost.message)
        XCTAssertTrue(HanaProcessProbe.waitForExit(of: processIdentifier, within: Self.callDeadline))
    }

    func testTheCancelDeadlineIsTheForcedSeverGraceTheHelperAnnouncedPlusTenSeconds() throws {
        let standIn = try standIn("""
            \(HanaStandInFrame.greeting(#"{"protocol":1,"forcedSeverGraceSeconds":1}"#))
            /usr/bin/head -c 13 > /dev/null
            \(HanaStandInFrame.frame(id: 1, code: 0, body: #"{"session":7}"#))
            \(HanaStandInFrame.absorbInput())
            """)
        let bridge = makeBridge(trust: Self.developmentHost, locateExecutable: { standIn })
        let session = try open(on: bridge, port: 30_015)
        let ticket = HanaOperationTicket(session: session, operation: 1)
        let call = HanaBlockingCall { try bridge.connect(ticket) }
        let cancelled = Date()

        bridge.cancel(ticket)

        let lost = try failure(of: call)
        let elapsed = Date().timeIntervalSince(cancelled)
        XCTAssertEqual(lost.kind, .connectionLost)
        XCTAssertTrue(lost.message.contains("still running 11 seconds later"), lost.message)
        XCTAssertGreaterThanOrEqual(elapsed, 10)
        XCTAssertLessThan(elapsed, 25)
    }

    func testClosingASessionShutsItsHelperDownAndTheNextOpenStartsANewOne() throws {
        let bridge = makeBridge()
        let port = try HanaLoopbackSocket.closedPort()
        let session = try open(on: bridge, port: port)
        let firstHelper = try XCTUnwrap(bridge.helperProcessIdentifier(serving: session))

        bridge.close(session: session)

        XCTAssertNil(bridge.helperProcessIdentifier(serving: session))
        XCTAssertTrue(HanaProcessProbe.waitForExit(of: firstHelper, within: Self.callDeadline))
        XCTAssertThrowsError(try bridge.connect(HanaOperationTicket(session: session, operation: 1))) { error in
            XCTAssertEqual(error as? HanaBridgeFailure, .closed)
        }
        let next = try open(on: bridge, port: port)
        let secondHelper = try XCTUnwrap(bridge.helperProcessIdentifier(serving: next))
        XCTAssertNotEqual(secondHelper, firstHelper)
        XCTAssertTrue(HanaProcessProbe.isRunning(secondHelper))
    }

    func testShutdownMakesTheHelperExit() throws {
        let bridge = makeBridge()
        let session = try open(on: bridge, port: HanaLoopbackSocket.closedPort())
        let processIdentifier = try XCTUnwrap(bridge.helperProcessIdentifier(serving: session))

        bridge.shutdown()

        XCTAssertNil(bridge.helperProcessIdentifier(serving: session))
        XCTAssertTrue(HanaProcessProbe.waitForExit(of: processIdentifier, within: Self.callDeadline))
        XCTAssertThrowsError(try bridge.connect(HanaOperationTicket(session: session, operation: 1))) { error in
            XCTAssertEqual(error as? HanaBridgeFailure, .closed)
        }
    }

    func testTheBundledHelperIsStoppedWhenItFailsTheRunningCodeCheck() throws {
        let simulated = HanaBridgeFailure(kind: .internalFailure, message: "simulated signature failure")
        let checks = HanaRunningCodeChecks(failingWith: simulated)
        let helper = try XCTUnwrap(bundledHelper)
        let bridge = makeBridge(
            trust: HanaHelperTrust(signingTeam: Self.foreignTeam, admitsUnsignedHost: false, checkRunningCode: checks.record),
            locateExecutable: { helper }
        )

        XCTAssertThrowsError(try open(on: bridge, port: HanaLoopbackSocket.closedPort())) { error in
            XCTAssertEqual(error as? HanaBridgeFailure, simulated)
        }

        let checked = try XCTUnwrap(checks.requests.first)
        XCTAssertEqual(checked.requirement, HanaHelperTrust.requirement(forTeam: Self.foreignTeam))
        XCTAssertTrue(HanaProcessProbe.waitForExit(of: checked.processIdentifier, within: Self.callDeadline))
    }

    func testAHelperSignedByAnotherTeamIsRefusedByTheRunningCodeCheck() throws {
        let checks = HanaRunningCodeChecks()
        let helper = try XCTUnwrap(bundledHelper)
        let trust = HanaHelperTrust(signingTeam: Self.foreignTeam, admitsUnsignedHost: false) { processIdentifier, requirement in
            try checks.record(processIdentifier, requirement)
            try HanaHelperTrust.checkRunningCode(processIdentifier: processIdentifier, requirement: requirement)
        }
        let bridge = makeBridge(trust: trust, locateExecutable: { helper })

        XCTAssertThrowsError(try open(on: bridge, port: HanaLoopbackSocket.closedPort())) { error in
            let failure = error as? HanaBridgeFailure
            XCTAssertEqual(failure?.kind, .internalFailure, "got \(error)")
            XCTAssertEqual(failure?.message.contains("does not satisfy"), true, "\(error)")
        }

        let checked = try XCTUnwrap(checks.requests.first)
        XCTAssertTrue(HanaProcessProbe.waitForExit(of: checked.processIdentifier, within: Self.callDeadline))
    }

    func testAStandInThatFailsTheRunningCodeCheckIsSentNoBytes() throws {
        let received = try standInFile("received")
        let recordedIdentifier = try standInFile("pid")
        let standIn = try standIn("""
            echo $$ > '\(recordedIdentifier.path)'
            \(HanaStandInFrame.greeting())
            \(HanaStandInFrame.absorbInput(into: received))
            """)
        let checks = HanaRunningCodeChecks(failingWith: HanaBridgeFailure(kind: .internalFailure, message: "refused"))
        let bridge = makeBridge(
            trust: HanaHelperTrust(signingTeam: Self.foreignTeam, admitsUnsignedHost: false, checkRunningCode: checks.record),
            locateExecutable: { standIn }
        )

        XCTAssertThrowsError(try open(on: bridge, port: 30_015))

        let processIdentifier = try XCTUnwrap(HanaFileProbe.processIdentifier(recordedAt: recordedIdentifier, within: Self.callDeadline))
        XCTAssertEqual(checks.requests.map(\.processIdentifier), [processIdentifier])
        XCTAssertTrue(HanaProcessProbe.waitForExit(of: processIdentifier, within: Self.callDeadline))
        XCTAssertEqual(HanaFileProbe.byteCount(at: received), 0)
    }

    func testAnOpenTheHelperNeverAnswersFailsAtTheDeadlineAndFreesTheConnectionQueue() async throws {
        let received = try standInFile("received")
        let recordedIdentifier = try standInFile("pid")
        let standIn = try standIn("""
            echo $$ > '\(recordedIdentifier.path)'
            \(HanaStandInFrame.greeting())
            \(HanaStandInFrame.absorbInput(into: received))
            """)
        let bridge = makeBridge(trust: Self.developmentHost, openDeadline: 1, locateExecutable: { standIn })
        let connection = HanaConnection(bridge: bridge)

        let started = Date()
        await assertOpenMissesItsDeadline(on: connection)

        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertGreaterThan(HanaFileProbe.byteCount(at: received), HanaHelperFrameHeader.byteCount)
        let first = try XCTUnwrap(HanaFileProbe.processIdentifier(recordedAt: recordedIdentifier, within: 1))
        XCTAssertTrue(HanaProcessProbe.waitForExit(of: first, within: Self.callDeadline))
        try FileManager.default.removeItem(at: recordedIdentifier)

        await assertOpenMissesItsDeadline(on: connection)

        let second = try XCTUnwrap(HanaFileProbe.processIdentifier(recordedAt: recordedIdentifier, within: 1))
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(HanaProcessProbe.waitForExit(of: second, within: Self.callDeadline))
    }

    func testCancellingAConnectWhileTheHelperHoldsItsOpenThrowsCancellationAndStopsTheHelper() async throws {
        let received = try standInFile("received")
        let recordedIdentifier = try standInFile("pid")
        let standIn = try standIn("""
            echo $$ > '\(recordedIdentifier.path)'
            \(HanaStandInFrame.greeting())
            \(HanaStandInFrame.absorbInput(into: received))
            """)
        let bridge = makeBridge(trust: Self.developmentHost, openDeadline: Self.callDeadline, locateExecutable: { standIn })
        let driver = HanaPluginDriver(
            config: DriverConnectionConfig(
                host: "127.0.0.1",
                port: 30_015,
                username: "SYSTEM",
                password: "test-only",
                database: "",
                ssl: SSLConfiguration(mode: .disabled)
            ),
            session: HanaConnection(bridge: bridge)
        )
        let connect = Task { try await driver.connect() }
        XCTAssertTrue(
            HanaFileProbe.waitForBytes(at: received, reaching: HanaHelperFrameHeader.byteCount + 1, within: Self.callDeadline),
            "the stand-in never received the open request"
        )
        let processIdentifier = try XCTUnwrap(HanaFileProbe.processIdentifier(recordedAt: recordedIdentifier, within: 1))
        let cancelled = Date()

        connect.cancel()

        do {
            try await connect.value
            XCTFail("a cancelled connect should not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 5)
        XCTAssertTrue(HanaProcessProbe.waitForExit(of: processIdentifier, within: Self.callDeadline))
    }

    private static func connectConfiguration(host: String = "127.0.0.1", port: Int = 30_015) -> HanaConnectConfiguration {
        HanaConnectConfiguration(
            host: host,
            port: port,
            username: "SYSTEM",
            password: "test-only",
            schema: "",
            tlsMode: .disabled,
            tlsServerName: "",
            caCertificatePath: "",
            clientCertificatePath: "",
            clientKeyPath: "",
            connectTimeoutSeconds: 120
        )
    }

    private func makeBridge(
        trust: HanaHelperTrust = .host,
        cancelDeadline: TimeInterval? = nil,
        openDeadline: TimeInterval = HanaHelperBridge.defaultOpenDeadline,
        locateExecutable: (@Sendable () throws -> URL)? = nil
    ) -> HanaHelperBridge {
        let bridge = HanaHelperBridge(
            trust: trust,
            cancelDeadline: cancelDeadline,
            openDeadline: openDeadline,
            locateExecutable: locateExecutable
        )
        bridges.append(bridge)
        return bridge
    }

    private func assertOpenMissesItsDeadline(
        on connection: HanaConnection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await connection.connect(Self.connectConfiguration())
            XCTFail("an open the helper never answers should fail", file: file, line: line)
        } catch {
            let failure = error as? HanaBridgeFailure
            XCTAssertEqual(failure?.kind, .internalFailure, "got \(error)", file: file, line: line)
            XCTAssertEqual(
                failure?.message.contains("did not answer the connection request within 1 seconds"),
                true,
                "\(error)",
                file: file,
                line: line
            )
        }
    }

    private func standIn(_ body: String) throws -> URL {
        try XCTUnwrap(folder).script(body)
    }

    private func standInFile(_ name: String) throws -> URL {
        try XCTUnwrap(folder).file(named: name)
    }

    private func open(on bridge: HanaHelperBridge, port: Int) throws -> UInt64 {
        try bridge.open(configuration: configuration(port: port), interruption: HanaOpenInterruption())
    }

    private func blockedConnect(on bridge: HanaHelperBridge) throws -> (HanaOperationTicket, HanaBlockingCall) {
        let server = try HanaSilentServer()
        servers.append(server)
        let session = try open(on: bridge, port: server.port)
        let ticket = HanaOperationTicket(session: session, operation: 1)
        let call = HanaBlockingCall { try bridge.connect(ticket) }
        XCTAssertTrue(server.awaitConnection(within: Self.callDeadline), "the helper never dialled the test server")
        XCTAssertFalse(call.hasFinished, "the connect should still be waiting for the server")
        return (ticket, call)
    }

    private func failure(of call: HanaBlockingCall) throws -> HanaBridgeFailure {
        let outcome = try XCTUnwrap(call.outcome(within: Self.callDeadline), "the call never finished")
        guard case .failure(let error) = outcome else {
            XCTFail("the call should fail")
            return HanaBridgeFailure(kind: .internalFailure)
        }
        return try XCTUnwrap(error as? HanaBridgeFailure, "got \(error)")
    }

    private func configuration(host: String = "127.0.0.1", port: Int) throws -> Data {
        try JSONEncoder().encode(Self.connectConfiguration(host: host, port: port))
    }
}
