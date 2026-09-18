import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class MCPProgressEmitterTests: XCTestCase {
    func testEmitterWithoutATokenWritesNothing() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(progressToken: nil, responder: MCPResponder(sink: sink, requestId: .number(1)))

        let hasToken = await emitter.hasProgressToken
        XCTAssertFalse(hasToken)

        await emitter.emit(progress: 0.5)
        await emitter.emit(progress: 1.0, total: 1.0, message: "done")

        let frames = await sink.sseFrames
        let heads = await sink.sseHeadCount
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(heads, 0)
    }

    func testEmitWritesAProgressNotificationThroughTheResponder() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(
            progressToken: .string("progress-1"),
            responder: MCPResponder(sink: sink, requestId: .number(1))
        )

        await emitter.emit(progress: 0.42)

        let heads = await sink.sseHeadCount
        XCTAssertEqual(heads, 1)

        let messages = try await sink.sseMessages()
        XCTAssertEqual(messages.count, 1)

        guard case .notification(let notification) = messages[0] else {
            XCTFail("Expected a notification, got \(messages[0])")
            return
        }
        XCTAssertEqual(notification.method, "notifications/progress")
        XCTAssertEqual(notification.params?["progressToken"]?.stringValue, "progress-1")
        XCTAssertEqual(notification.params?["progress"]?.doubleValue, 0.42)
        XCTAssertNil(notification.params?["total"])
        XCTAssertNil(notification.params?["message"])
    }

    func testAnIntegerProgressTokenIsEchoedAsAnInteger() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(
            progressToken: .number(17),
            responder: MCPResponder(sink: sink, requestId: .number(1))
        )

        await emitter.emit(progress: 1)

        let messages = try await sink.sseMessages()
        guard case .notification(let notification) = try XCTUnwrap(messages.first) else {
            XCTFail("Expected a notification")
            return
        }
        XCTAssertEqual(notification.params?["progressToken"]?.intValue, 17)
    }

    func testTotalAndMessageAreCarriedWhenProvided() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(
            progressToken: .string("token"),
            responder: MCPResponder(sink: sink, requestId: .number(1))
        )

        await emitter.emit(progress: 3, total: 10, message: "reading rows")

        let messages = try await sink.sseMessages()
        guard case .notification(let notification) = try XCTUnwrap(messages.first) else {
            XCTFail("Expected a notification")
            return
        }
        XCTAssertEqual(notification.params?["progress"]?.doubleValue, 3)
        XCTAssertEqual(notification.params?["total"]?.doubleValue, 10)
        XCTAssertEqual(notification.params?["message"]?.stringValue, "reading rows")
    }

    func testAnEmptyMessageIsOmitted() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(
            progressToken: .string("token"),
            responder: MCPResponder(sink: sink, requestId: .number(1))
        )

        await emitter.emit(progress: 1, total: nil, message: "")

        let messages = try await sink.sseMessages()
        guard case .notification(let notification) = try XCTUnwrap(messages.first) else {
            XCTFail("Expected a notification")
            return
        }
        XCTAssertNil(notification.params?["message"])
    }

    func testProgressThatDoesNotAdvanceIsDropped() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(
            progressToken: .string("token"),
            responder: MCPResponder(sink: sink, requestId: .number(1))
        )

        await emitter.emit(progress: 0.5)
        await emitter.emit(progress: 0.5)
        await emitter.emit(progress: 0.4)
        await emitter.emit(progress: 0.6)

        let messages = try await sink.sseMessages()
        XCTAssertEqual(messages.count, 2)

        let reported = messages.compactMap { message -> Double? in
            guard case .notification(let notification) = message else { return nil }
            return notification.params?["progress"]?.doubleValue
        }
        XCTAssertEqual(reported, [0.5, 0.6])
    }

    func testProgressThatIsNotFiniteIsDropped() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(
            progressToken: .string("token"),
            responder: MCPResponder(sink: sink, requestId: .number(1))
        )

        await emitter.emit(progress: .infinity)
        await emitter.emit(progress: .nan)

        let frames = await sink.sseFrames
        XCTAssertTrue(frames.isEmpty)
    }

    func testANonFiniteTotalIsOmitted() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(
            progressToken: .string("token"),
            responder: MCPResponder(sink: sink, requestId: .number(1))
        )

        await emitter.emit(progress: 1, total: .infinity)

        let messages = try await sink.sseMessages()
        guard case .notification(let notification) = try XCTUnwrap(messages.first) else {
            XCTFail("Expected a notification")
            return
        }
        XCTAssertNil(notification.params?["total"])
    }

    func testTheEmitterTakesItsTokenFromTheRequestMeta() async throws {
        let sink = RecordingResponderSink()
        let meta = MCPProtocolTestSupport.makeMeta(progressToken: .string("from-meta"))
        let emitter = MCPProgressEmitter(meta: meta, responder: MCPResponder(sink: sink, requestId: .number(1)))

        let hasToken = await emitter.hasProgressToken
        XCTAssertTrue(hasToken)

        await emitter.emit(progress: 1)

        let messages = try await sink.sseMessages()
        guard case .notification(let notification) = try XCTUnwrap(messages.first) else {
            XCTFail("Expected a notification")
            return
        }
        XCTAssertEqual(notification.params?["progressToken"]?.stringValue, "from-meta")
    }

    func testARequestWithoutATokenInItsMetaEmitsNothing() async throws {
        let sink = RecordingResponderSink()
        let meta = MCPProtocolTestSupport.makeMeta()
        let emitter = MCPProgressEmitter(meta: meta, responder: MCPResponder(sink: sink, requestId: .number(1)))

        await emitter.emit(progress: 1)

        let frames = await sink.sseFrames
        XCTAssertTrue(frames.isEmpty)
    }

    func testProgressIsNotEmittedAfterTheResponseIsComplete() async throws {
        let sink = RecordingResponderSink()
        let responder = MCPResponder(sink: sink, requestId: .number(1))
        let emitter = MCPProgressEmitter(progressToken: .string("token"), responder: responder)

        await responder.respond(.successResponse(JsonRpcSuccessResponse(id: .number(1), result: .object([:]))))
        await emitter.emit(progress: 1)

        let frames = await sink.sseFrames
        XCTAssertTrue(frames.isEmpty)
    }
}
