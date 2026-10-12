import Foundation
import XCTest

final class HanaHelperProcessTests: XCTestCase {
    private static let gibibyte = 1 << 30

    private var folder: HanaStandInFolder?

    override func setUpWithError() throws {
        folder = try HanaStandInFolder(named: "HanaHelperProcessTests")
    }

    override func tearDown() {
        folder?.remove()
        super.tearDown()
    }

    func testTheGreetingCarriesTheHelpersForcedSeverGrace() throws {
        let helper = try script("""
            \(HanaStandInFrame.greeting(#"{"protocol":1,"forcedSeverGraceSeconds":7}"#))
            \(HanaStandInFrame.absorbInput())
            """)

        let launched = try HanaHelperProcess.launch(executable: helper, handshakeDeadline: 30)
        defer { launched.process.shutdown() }

        XCTAssertEqual(launched.greeting, HanaHelperGreeting(forcedSeverGrace: 7))
    }

    func testAHelperSpeakingAnotherProtocolIsRefusedByNumber() throws {
        let helper = try script("""
            \(HanaStandInFrame.greeting(#"{"protocol":2,"forcedSeverGraceSeconds":30}"#))
            \(HanaStandInFrame.absorbInput())
            """)

        XCTAssertThrowsError(try HanaHelperProcess.launch(executable: helper, handshakeDeadline: 30)) { error in
            XCTAssertEqual(error as? HanaBridgeFailure, HanaBridgeFailure(
                kind: .internalFailure,
                message: "incompatible helper protocol 2"
            ))
        }
    }

    func testAGreetingThatNamesNoForcedSeverGraceIsRefused() throws {
        let helper = try script("""
            \(HanaStandInFrame.greeting(#"{"protocol":1}"#))
            \(HanaStandInFrame.absorbInput())
            """)

        XCTAssertThrowsError(try HanaHelperProcess.launch(executable: helper, handshakeDeadline: 30)) { error in
            XCTAssertEqual(error as? HanaBridgeFailure, HanaHelperFrameError.unusableForcedSeverGrace.failure)
            XCTAssertEqual((error as? HanaBridgeFailure)?.message.hasPrefix("incompatible helper"), true, "\(error)")
        }
    }

    func testAHandshakeOverFourKibibytesIsRefusedBeforeItsBodyArrives() throws {
        let helper = try script("""
            \(HanaStandInFrame.header(bodyLength: 4_097, id: 0, code: 0))
            \(HanaStandInFrame.absorbInput())
            """)
        let started = Date()

        XCTAssertThrowsError(try HanaHelperProcess.launch(executable: helper, handshakeDeadline: 30)) { error in
            XCTAssertEqual(error as? HanaBridgeFailure, HanaBridgeFailure(
                kind: .internalFailure,
                message: "the helper announced a 4097-byte frame, over the 4096-byte limit"
            ))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testAHelperThatNeverGreetsIsStoppedAtTheHandshakeDeadline() throws {
        let helper = try script("exec /bin/sleep 30")

        XCTAssertThrowsError(try HanaHelperProcess.launch(executable: helper, handshakeDeadline: 1)) { error in
            let failure = error as? HanaBridgeFailure
            XCTAssertEqual(failure?.kind, .internalFailure, "got \(error)")
            XCTAssertEqual(failure?.message.contains("did not answer within 1 seconds"), true, "\(error)")
        }
    }

    func testInterruptingAHandshakeStopsTheHelperWithoutWaitingForTheDeadline() throws {
        let recordedIdentifier = try XCTUnwrap(folder).file(named: "pid")
        let helper = try script("""
            echo $$ > '\(recordedIdentifier.path)'
            \(HanaStandInFrame.absorbInput())
            """)
        let interruption = HanaOpenInterruption()
        let launch = HanaBlockingCall {
            _ = try HanaHelperProcess.launch(executable: helper, handshakeDeadline: 30, interruption: interruption)
            return Data()
        }
        let helperIdentifier = try XCTUnwrap(HanaFileProbe.processIdentifier(recordedAt: recordedIdentifier, within: 10))
        let interrupted = Date()

        interruption.interrupt()

        let outcome = try XCTUnwrap(launch.outcome(within: 10), "the launch never finished")
        XCTAssertLessThan(Date().timeIntervalSince(interrupted), 5)
        guard case .failure(let error) = outcome else {
            XCTFail("an interrupted handshake should fail")
            return
        }
        XCTAssertEqual(error as? HanaBridgeFailure, HanaHelperProcess.interruptedFailure)
        XCTAssertTrue(HanaProcessProbe.waitForExit(of: helperIdentifier, within: 10))
    }

    func testAHelperThatExitsBeforeGreetingReportsItsStatusAndErrorOutput() throws {
        let helper = try script("""
            echo 'panic: invalid type code' >&2
            exit 2
            """)

        XCTAssertThrowsError(try HanaHelperProcess.launch(executable: helper, handshakeDeadline: 30)) { error in
            let failure = error as? HanaBridgeFailure
            XCTAssertEqual(failure?.kind, .internalFailure, "got \(error)")
            XCTAssertEqual(failure?.message.contains("exited with status 2"), true, "\(error)")
            XCTAssertEqual(failure?.message.contains("panic: invalid type code"), true, "\(error)")
        }
    }

    func testAReplyToAFrameNobodyIssuedLosesTheConnectionAndNamesTheViolation() throws {
        let helper = try script("""
            \(HanaStandInFrame.greeting())
            /usr/bin/head -c 15 > /dev/null
            \(HanaStandInFrame.frame(id: 999, code: 0, body: "{}"))
            \(HanaStandInFrame.absorbInput())
            """)
        let process = try HanaHelperProcess.launch(executable: helper, handshakeDeadline: 30).process
        defer { process.shutdown() }

        XCTAssertThrowsError(try process.call(.ping, body: Data("{}".utf8), ticket: nil)) { error in
            let failure = error as? HanaBridgeFailure
            XCTAssertEqual(failure?.kind, .connectionLost, "got \(error)")
            XCTAssertEqual(failure?.message.contains("the helper answered frame 999, which no call is waiting for"), true, "\(error)")
        }
        XCTAssertFalse(process.isAlive)
        XCTAssertThrowsError(try process.call(.ping, body: Data("{}".utf8), ticket: nil)) { error in
            let failure = error as? HanaBridgeFailure
            XCTAssertEqual(failure?.kind, .connectionLost, "got \(error)")
            XCTAssertEqual(failure?.message.contains("frame 999"), true, "\(error)")
        }
    }

    func testAReplyAnnouncingMoreThanTwoGibibytesIsRefusedWithoutAllocatingIt() throws {
        let helper = try script("""
            \(HanaStandInFrame.greeting())
            /usr/bin/head -c 15 > /dev/null
            \(HanaStandInFrame.header(bodyLength: UInt32.max, id: 1, code: 0))
            \(HanaStandInFrame.absorbInput())
            """)
        let process = try HanaHelperProcess.launch(executable: helper, handshakeDeadline: 30).process
        defer { process.shutdown() }
        let peakBefore = HanaMemoryProbe.peakResidentByteCount

        XCTAssertThrowsError(try process.call(.ping, body: Data("{}".utf8), ticket: nil)) { error in
            let failure = error as? HanaBridgeFailure
            XCTAssertEqual(failure?.kind, .connectionLost, "got \(error)")
            XCTAssertEqual(
                failure?.message.contains("the helper announced a 4294967295-byte frame, over the 2147483647-byte limit"),
                true,
                "\(error)"
            )
        }

        XCTAssertLessThan(HanaMemoryProbe.peakResidentByteCount - peakBefore, Self.gibibyte)
        XCTAssertFalse(process.isAlive)
    }

    func testAReplyCutShortLosesTheConnection() throws {
        let helper = try script("""
            \(HanaStandInFrame.greeting())
            /usr/bin/head -c 15 > /dev/null
            \(HanaStandInFrame.header(bodyLength: 100_000, id: 1, code: 0))
            /usr/bin/printf '{"partial"'
            exit 0
            """)
        let process = try HanaHelperProcess.launch(executable: helper, handshakeDeadline: 30).process
        defer { process.shutdown() }

        XCTAssertThrowsError(try process.call(.ping, body: Data("{}".utf8), ticket: nil)) { error in
            let failure = error as? HanaBridgeFailure
            XCTAssertEqual(failure?.kind, .connectionLost, "got \(error)")
            XCTAssertEqual(failure?.message.contains("after 10 of 100000 bytes"), true, "\(error)")
        }
    }

    func testCallsAfterTheHelperEndedFailWithoutWriting() throws {
        let helper = try script("""
            \(HanaStandInFrame.greeting())
            exit 0
            """)
        let process = try HanaHelperProcess.launch(executable: helper, handshakeDeadline: 30).process
        defer { process.shutdown() }

        XCTAssertThrowsError(try process.call(.ping, body: Data("{}".utf8), ticket: nil)) { error in
            XCTAssertEqual((error as? HanaBridgeFailure)?.kind, .connectionLost, "got \(error)")
        }
        XCTAssertNil(process.post(.close, body: Data(#"{"session":1}"#.utf8)))
        XCTAssertThrowsError(try process.call(.ping, body: Data("{}".utf8), ticket: nil)) { error in
            XCTAssertEqual((error as? HanaBridgeFailure)?.message.contains("exited with status 0"), true, "\(error)")
        }
    }

    func testAStoppedHelperRefusesNewCallsAsLost() throws {
        let helper = try script("""
            \(HanaStandInFrame.greeting())
            \(HanaStandInFrame.absorbInput())
            """)
        let process = try HanaHelperProcess.launch(executable: helper, handshakeDeadline: 30).process
        defer { process.shutdown() }

        process.stop(cause: "TablePro stopped it for the test.")

        XCTAssertFalse(process.isAlive)
        XCTAssertThrowsError(try process.call(.ping, body: Data("{}".utf8), ticket: nil)) { error in
            let failure = error as? HanaBridgeFailure
            XCTAssertEqual(failure?.kind, .connectionLost, "got \(error)")
            XCTAssertEqual(failure?.message.contains("TablePro stopped it for the test."), true, "\(error)")
        }
        XCTAssertNil(process.post(.close, body: Data(#"{"session":1}"#.utf8)))
    }

    func testACallInFlightWhenTableProShutsTheHelperDownFailsAsClosed() async throws {
        let received = try XCTUnwrap(folder).file(named: "received")
        let helper = try script("""
            \(HanaStandInFrame.greeting())
            \(HanaStandInFrame.absorbInput(into: received))
            """)
        let process = try HanaHelperProcess.launch(executable: helper, handshakeDeadline: 30).process
        let ping = Task.detached { try process.call(.ping, body: Data("{}".utf8), ticket: nil) }
        XCTAssertTrue(
            HanaFileProbe.waitForBytes(at: received, reaching: HanaHelperFrameHeader.byteCount, within: 10),
            "the stand-in never received the ping"
        )

        process.shutdown()

        do {
            _ = try await ping.value
            XCTFail("a ping the helper never answered should fail")
        } catch {
            XCTAssertEqual((error as? HanaBridgeFailure)?.kind, .closed, "got \(error)")
        }
    }

    func testACallAfterTableProShutTheHelperDownFailsAsClosed() throws {
        let helper = try script("""
            \(HanaStandInFrame.greeting())
            \(HanaStandInFrame.absorbInput())
            """)
        let process = try HanaHelperProcess.launch(executable: helper, handshakeDeadline: 30).process

        process.shutdown()

        XCTAssertFalse(process.isAlive)
        XCTAssertThrowsError(try process.call(.ping, body: Data("{}".utf8), ticket: nil)) { error in
            XCTAssertEqual((error as? HanaBridgeFailure)?.kind, .closed, "got \(error)")
        }
    }

    private func script(_ body: String) throws -> URL {
        try XCTUnwrap(folder).script(body)
    }
}
