import Foundation
@testable import TableProMCP
import TableProMCPTestSupport
import Testing

struct MCPProgressEmitterTests {
    @Test func testEmitterWithoutATokenWritesNothing() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(progressToken: nil, responder: MCPResponder(sink: sink, requestId: .number(1)))

        let hasToken = await emitter.hasProgressToken
        #expect(!hasToken)

        await emitter.emit(progress: 0.5)
        await emitter.emit(progress: 1.0, total: 1.0, message: "done")

        let frames = await sink.sseFrames
        let heads = await sink.sseHeadCount
        #expect(frames.isEmpty)
        #expect(heads == 0)
    }

    @Test func testEmitWritesAProgressNotificationThroughTheResponder() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(
            progressToken: .string("progress-1"),
            responder: MCPResponder(sink: sink, requestId: .number(1))
        )

        await emitter.emit(progress: 0.42)

        let heads = await sink.sseHeadCount
        #expect(heads == 1)

        let messages = try await sink.sseMessages()
        #expect(messages.count == 1)

        guard case .notification(let notification) = messages[0] else {
            Issue.record("Expected a notification, got \(messages[0])")
            return
        }
        #expect(notification.method == "notifications/progress")
        #expect(notification.params?["progressToken"]?.stringValue == "progress-1")
        #expect(notification.params?["progress"]?.doubleValue == 0.42)
        #expect(notification.params?["total"] == nil)
        #expect(notification.params?["message"] == nil)
    }

    @Test func testAnIntegerProgressTokenIsEchoedAsAnInteger() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(
            progressToken: .number(17),
            responder: MCPResponder(sink: sink, requestId: .number(1))
        )

        await emitter.emit(progress: 1)

        let messages = try await sink.sseMessages()
        guard case .notification(let notification) = try #require(messages.first) else {
            Issue.record("Expected a notification")
            return
        }
        #expect(notification.params?["progressToken"]?.intValue == 17)
    }

    @Test func testTotalAndMessageAreCarriedWhenProvided() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(
            progressToken: .string("token"),
            responder: MCPResponder(sink: sink, requestId: .number(1))
        )

        await emitter.emit(progress: 3, total: 10, message: "reading rows")

        let messages = try await sink.sseMessages()
        guard case .notification(let notification) = try #require(messages.first) else {
            Issue.record("Expected a notification")
            return
        }
        #expect(notification.params?["progress"]?.doubleValue == 3)
        #expect(notification.params?["total"]?.doubleValue == 10)
        #expect(notification.params?["message"]?.stringValue == "reading rows")
    }

    @Test func testAnEmptyMessageIsOmitted() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(
            progressToken: .string("token"),
            responder: MCPResponder(sink: sink, requestId: .number(1))
        )

        await emitter.emit(progress: 1, total: nil, message: "")

        let messages = try await sink.sseMessages()
        guard case .notification(let notification) = try #require(messages.first) else {
            Issue.record("Expected a notification")
            return
        }
        #expect(notification.params?["message"] == nil)
    }

    @Test func testProgressThatDoesNotAdvanceIsDropped() async throws {
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
        #expect(messages.count == 2)

        let reported = messages.compactMap { message -> Double? in
            guard case .notification(let notification) = message else { return nil }
            return notification.params?["progress"]?.doubleValue
        }
        #expect(reported == [0.5, 0.6])
    }

    @Test func testProgressThatIsNotFiniteIsDropped() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(
            progressToken: .string("token"),
            responder: MCPResponder(sink: sink, requestId: .number(1))
        )

        await emitter.emit(progress: .infinity)
        await emitter.emit(progress: .nan)

        let frames = await sink.sseFrames
        #expect(frames.isEmpty)
    }

    @Test func testANonFiniteTotalIsOmitted() async throws {
        let sink = RecordingResponderSink()
        let emitter = MCPProgressEmitter(
            progressToken: .string("token"),
            responder: MCPResponder(sink: sink, requestId: .number(1))
        )

        await emitter.emit(progress: 1, total: .infinity)

        let messages = try await sink.sseMessages()
        guard case .notification(let notification) = try #require(messages.first) else {
            Issue.record("Expected a notification")
            return
        }
        #expect(notification.params?["total"] == nil)
    }

    @Test func testTheEmitterTakesItsTokenFromTheRequestMeta() async throws {
        let sink = RecordingResponderSink()
        let meta = MCPProtocolTestSupport.makeMeta(progressToken: .string("from-meta"))
        let emitter = MCPProgressEmitter(meta: meta, responder: MCPResponder(sink: sink, requestId: .number(1)))

        let hasToken = await emitter.hasProgressToken
        #expect(hasToken)

        await emitter.emit(progress: 1)

        let messages = try await sink.sseMessages()
        guard case .notification(let notification) = try #require(messages.first) else {
            Issue.record("Expected a notification")
            return
        }
        #expect(notification.params?["progressToken"]?.stringValue == "from-meta")
    }

    @Test func testARequestWithoutATokenInItsMetaEmitsNothing() async throws {
        let sink = RecordingResponderSink()
        let meta = MCPProtocolTestSupport.makeMeta()
        let emitter = MCPProgressEmitter(meta: meta, responder: MCPResponder(sink: sink, requestId: .number(1)))

        await emitter.emit(progress: 1)

        let frames = await sink.sseFrames
        #expect(frames.isEmpty)
    }

    @Test func testProgressIsNotEmittedAfterTheResponseIsComplete() async throws {
        let sink = RecordingResponderSink()
        let responder = MCPResponder(sink: sink, requestId: .number(1))
        let emitter = MCPProgressEmitter(progressToken: .string("token"), responder: responder)

        await responder.respond(.successResponse(JsonRpcSuccessResponse(id: .number(1), result: .object([:]))))
        await emitter.emit(progress: 1)

        let frames = await sink.sseFrames
        #expect(frames.isEmpty)
    }
}
