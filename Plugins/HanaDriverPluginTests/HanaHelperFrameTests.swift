import Foundation
import XCTest

final class HanaHelperFrameTests: XCTestCase {
    func testHeaderIsLengthThenIdThenCodeInBigEndian() {
        let header = HanaHelperFrameHeader(bodyLength: 7, id: 0x0102_0304_0506_0708, code: 3)

        XCTAssertEqual([UInt8](header.encoded), [0, 0, 0, 7, 1, 2, 3, 4, 5, 6, 7, 8, 3])
    }

    func testHeaderRoundTripsAtTheLimitsOfEveryField() throws {
        let headers = [
            HanaHelperFrameHeader(bodyLength: 0, id: 0, code: 0),
            HanaHelperFrameHeader(bodyLength: UInt32.max, id: UInt64.max, code: UInt8.max),
            HanaHelperFrameHeader(bodyLength: 1 << 30, id: 42, code: 1)
        ]

        for header in headers {
            XCTAssertEqual(try HanaHelperFrameHeader(decoding: header.encoded), header)
        }
    }

    func testRequestEncodesItsBodyAfterTheHeader() throws {
        let body = Data(#"{"host":"db.example.com"}"#.utf8)
        let request = try HanaHelperRequest(id: 9, opcode: .open, body: body)
        let encoded = request.encoded

        let header = try HanaHelperFrameHeader(decoding: encoded.prefix(HanaHelperFrameHeader.byteCount))
        XCTAssertEqual(header, HanaHelperFrameHeader(bodyLength: UInt32(body.count), id: 9, code: 1))
        XCTAssertEqual(encoded.dropFirst(HanaHelperFrameHeader.byteCount), body)
        XCTAssertEqual(encoded.count, HanaHelperFrameHeader.byteCount + body.count)
    }

    func testEmptyRequestIsTheHeaderAlone() throws {
        let request = try HanaHelperRequest(id: 3, opcode: .cancel, body: Data())

        XCTAssertEqual(request.encoded.count, HanaHelperFrameHeader.byteCount)
        XCTAssertEqual(request.header.code, HanaHelperOpcode.cancel.rawValue)
    }

    func testOpcodesMatchTheHelperProtocol() {
        let opcodes: [HanaHelperOpcode] = [.open, .connect, .execute, .explain, .ping, .cancel, .close]

        XCTAssertEqual(opcodes.map(\.rawValue), [1, 2, 3, 4, 5, 6, 7])
    }

    func testRequestOverOneGibibyteIsRefusedBeforeSending() {
        let oversized = Data(count: HanaHelperRequest.maximumBodyLength + 1)

        XCTAssertThrowsError(try HanaHelperRequest(id: 1, opcode: .execute, body: oversized)) { error in
            XCTAssertEqual(
                error as? HanaHelperFrameError,
                .requestTooLarge(byteCount: HanaHelperRequest.maximumBodyLength + 1)
            )
        }
    }

    func testRequestOfExactlyOneGibibyteIsAccepted() throws {
        let largest = Data(count: HanaHelperRequest.maximumBodyLength)

        let request = try HanaHelperRequest(id: 1, opcode: .execute, body: largest)

        XCTAssertEqual(Int(request.header.bodyLength), HanaHelperRequest.maximumBodyLength)
    }

    func testHeaderShorterOrLongerThanThirteenBytesIsMalformed() {
        for count in [0, 1, 12, 14] {
            XCTAssertThrowsError(try HanaHelperFrameHeader(decoding: Data(count: count))) { error in
                XCTAssertEqual(error as? HanaHelperFrameError, .truncatedHeader(receivedByteCount: count))
            }
        }
    }

    func testSuccessReplyCarriesItsBody() throws {
        let body = Data(#"{"session":7}"#.utf8)

        XCTAssertEqual(try HanaHelperReply(status: 0, body: body), .success(body))
    }

    func testErrorReplyDecodesTheBridgeFailure() throws {
        let body = Data(#"{"kind":"connect","code":0,"position":0,"message":"refused","parameter":0,"expected":""}"#.utf8)

        let reply = try HanaHelperReply(status: 1, body: body)

        XCTAssertEqual(reply, .failure(HanaBridgeFailure(kind: .connect, message: "refused")))
    }

    func testErrorReplyThatIsNotJSONBecomesAnInternalFailure() throws {
        let reply = try HanaHelperReply(status: 1, body: Data("not json".utf8))

        XCTAssertEqual(reply, .failure(HanaBridgeFailure(kind: .internalFailure, message: "not json")))
    }

    func testUnknownReplyStatusIsMalformed() {
        XCTAssertThrowsError(try HanaHelperReply(status: 2, body: Data())) { error in
            XCTAssertEqual(error as? HanaHelperFrameError, .unknownStatus(2))
        }
    }

    func testHandshakeAcceptsProtocolOneAndReadsTheForcedSeverGrace() throws {
        let body = Data(#"{"protocol":1,"forcedSeverGraceSeconds":30}"#.utf8)
        let header = HanaHelperFrameHeader(bodyLength: UInt32(body.count), id: 0, code: 0)

        XCTAssertEqual(try HanaHelperHandshake.greeting(from: header, body: body), HanaHelperGreeting(forcedSeverGrace: 30))
    }

    func testHandshakeNamesAnIncompatibleProtocol() {
        let body = Data(#"{"protocol":2,"forcedSeverGraceSeconds":30}"#.utf8)
        let header = HanaHelperFrameHeader(bodyLength: UInt32(body.count), id: 0, code: 0)

        XCTAssertThrowsError(try HanaHelperHandshake.greeting(from: header, body: body)) { error in
            XCTAssertEqual(error as? HanaHelperFrameError, .incompatibleProtocol(2))
            XCTAssertEqual((error as? HanaHelperFrameError)?.failure.message, "incompatible helper protocol 2")
            XCTAssertEqual((error as? HanaHelperFrameError)?.failure.kind, .internalFailure)
        }
    }

    func testHandshakeWithoutAUsableForcedSeverGraceIsAnIncompatibleHelper() {
        let bodies = [
            #"{"protocol":1}"#,
            #"{"protocol":1,"forcedSeverGraceSeconds":null}"#,
            #"{"protocol":1,"forcedSeverGraceSeconds":0}"#,
            #"{"protocol":1,"forcedSeverGraceSeconds":-30}"#,
            #"{"protocol":1,"forcedSeverGraceSeconds":3601}"#
        ]

        for body in bodies {
            let header = HanaHelperFrameHeader(bodyLength: UInt32(body.utf8.count), id: 0, code: 0)
            XCTAssertThrowsError(try HanaHelperHandshake.greeting(from: header, body: Data(body.utf8))) { error in
                XCTAssertEqual(error as? HanaHelperFrameError, .unusableForcedSeverGrace, body)
                XCTAssertEqual((error as? HanaHelperFrameError)?.failure.kind, .internalFailure, body)
                XCTAssertEqual((error as? HanaHelperFrameError)?.message.hasPrefix("incompatible helper"), true, body)
            }
        }
    }

    func testHandshakeRefusesAnythingButAGreetingOnFrameZero() {
        let greeting = #"{"protocol":1,"forcedSeverGraceSeconds":30}"#
        let cases: [(HanaHelperFrameHeader, String)] = [
            (HanaHelperFrameHeader(bodyLength: 43, id: 1, code: 0), greeting),
            (HanaHelperFrameHeader(bodyLength: 43, id: 0, code: 1), greeting),
            (HanaHelperFrameHeader(bodyLength: 8, id: 0, code: 0), "garbage!"),
            (HanaHelperFrameHeader(bodyLength: 2, id: 0, code: 0), "{}"),
            (HanaHelperFrameHeader(bodyLength: 45, id: 0, code: 0), #"{"protocol":1,"forcedSeverGraceSeconds":"30"}"#)
        ]

        for (header, body) in cases {
            XCTAssertThrowsError(try HanaHelperHandshake.greeting(from: header, body: Data(body.utf8))) { error in
                XCTAssertEqual(error as? HanaHelperFrameError, .unexpectedHandshake, "\(header) \(body)")
            }
        }
    }

    func testFramesFromTheHelperAreCappedBelowTwoGibibytesAndTheHandshakeAtFourKibibytes() {
        XCTAssertEqual(HanaHelperReply.maximumBodyLength, 2_147_483_647)
        XCTAssertEqual(HanaHelperHandshake.maximumBodyLength, 4_096)
        XCTAssertEqual(
            HanaHelperFrameError.frameTooLarge(byteCount: 4_294_967_295, limit: 2_147_483_647).failure,
            HanaBridgeFailure(
                kind: .internalFailure,
                message: "the helper announced a 4294967295-byte frame, over the 2147483647-byte limit"
            )
        )
    }

    func testTheCancelDeadlineIsTheHelpersForcedSeverGracePlusTenSeconds() {
        XCTAssertEqual(HanaHelperBridge.cancelDeadline(forcedSeverGrace: 30), 40)
        XCTAssertEqual(HanaHelperBridge.cancelDeadline(forcedSeverGrace: 1), 11)
    }

    func testOperationBodyNamesTheSessionAndOperation() throws {
        let body = HanaHelperMessage.operation(HanaOperationTicket(session: 4, operation: UInt64.max))

        let decoded = try JSONDecoder().decode(OperationBody.self, from: body)
        XCTAssertEqual(decoded, OperationBody(session: 4, operation: UInt64.max))
    }

    func testStatementBodyEmbedsTheRequestUnchanged() throws {
        let request = try JSONEncoder().encode(
            HanaExecuteRequest(sql: "SELECT \"A\" FROM T WHERE X = ?", parameters: [.text("é\n")], rowCap: 10, timeoutSeconds: 5)
        )

        let body = HanaHelperMessage.statement(HanaOperationTicket(session: 2, operation: 3), request: request)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["session"] as? Int, 2)
        XCTAssertEqual(object["operation"] as? Int, 3)
        let embedded = try JSONSerialization.data(withJSONObject: XCTUnwrap(object["request"]), options: [.sortedKeys])
        let original = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: request),
            options: [.sortedKeys]
        )
        XCTAssertEqual(embedded, original)
    }

    func testSessionBodyNamesOnlyTheSession() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: HanaHelperMessage.session(11)) as? [String: Any])

        XCTAssertEqual(object.count, 1)
        XCTAssertEqual(object["session"] as? Int, 11)
    }

    func testOpenedSessionIsReadFromTheReply() throws {
        XCTAssertEqual(try HanaHelperMessage.openedSession(from: Data(#"{"session":18446744073709551615}"#.utf8)), UInt64.max)
    }

    func testOpenReplyWithoutAUsableSessionIsAnInternalFailure() {
        for reply in [#"{"session":0}"#, "{}", "[]", ""] {
            XCTAssertThrowsError(try HanaHelperMessage.openedSession(from: Data(reply.utf8))) { error in
                XCTAssertEqual((error as? HanaBridgeFailure)?.kind, .internalFailure, reply)
            }
        }
    }

    func testCancelWatchCoversOnlyItsOwnOperation() {
        let watch = HanaHelperCancelWatch(ticket: HanaOperationTicket(session: 1, operation: 5), issuedThrough: 10)

        XCTAssertTrue(watch.covers(callID: 4, ticket: HanaOperationTicket(session: 1, operation: 5)))
        XCTAssertTrue(watch.covers(callID: 12, ticket: HanaOperationTicket(session: 1, operation: 5)))
        XCTAssertFalse(watch.covers(callID: 4, ticket: HanaOperationTicket(session: 1, operation: 6)))
        XCTAssertFalse(watch.covers(callID: 4, ticket: HanaOperationTicket(session: 2, operation: 5)))
        XCTAssertFalse(watch.covers(callID: 4, ticket: nil))
    }

    func testCancelWatchForWhateverRunsCoversOnlyCallsIssuedBeforeTheCancel() {
        let watch = HanaHelperCancelWatch(ticket: HanaOperationTicket(session: 1, operation: 0), issuedThrough: 10)

        XCTAssertTrue(watch.covers(callID: 9, ticket: HanaOperationTicket(session: 1, operation: 7)))
        XCTAssertFalse(watch.covers(callID: 11, ticket: HanaOperationTicket(session: 1, operation: 8)))
        XCTAssertFalse(watch.covers(callID: 9, ticket: HanaOperationTicket(session: 2, operation: 7)))
    }

    func testOutputTailKeepsOnlyTheLastBytes() {
        var tail = HanaHelperOutputTail(limit: 8)

        tail.append(Data("panic: ".utf8))
        tail.append(Data("invalid type code".utf8))

        XCTAssertEqual(tail.bytes, Data("ype code".utf8))
        XCTAssertEqual(tail.text, "ype code")
    }

    func testOutputTailDefaultsToFourKibibytes() {
        var tail = HanaHelperOutputTail()

        tail.append(Data(repeating: UInt8(ascii: "a"), count: 5_000))
        tail.append(Data("\ngoroutine 1 [running]:\n".utf8))

        XCTAssertEqual(tail.bytes.count, 4_096)
        XCTAssertTrue(tail.text.hasSuffix("goroutine 1 [running]:"))
    }

    func testExitReportNamesTheStatusTheCauseAndTheTail() {
        let exited = HanaHelperExitReport(termination: .exited(status: 2), stopCause: nil, errorTail: "panic: boom")
        let killed = HanaHelperExitReport(termination: .signalled(9), stopCause: "TablePro stopped it.", errorTail: "")
        let unknown = HanaHelperExitReport(termination: .unknown, stopCause: nil, errorTail: "")

        XCTAssertEqual(exited.message, "The SAP HANA helper exited with status 2.\npanic: boom")
        XCTAssertEqual(exited.summary, "The SAP HANA helper exited with status 2.")
        XCTAssertEqual(killed.message, "TablePro stopped it. The SAP HANA helper was stopped by signal 9.")
        XCTAssertEqual(unknown.message, "The SAP HANA helper closed its output.")
    }
}

private struct OperationBody: Decodable, Equatable {
    let session: UInt64
    let operation: UInt64
}
