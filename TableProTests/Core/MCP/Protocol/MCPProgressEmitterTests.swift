import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class MCPProgressEmitterTests: XCTestCase {
    func testEmitWithoutProgressTokenIsNoop() async {
        let sink = StubProgressSink()
        let emitter = MCPProgressEmitter(
            progressToken: nil,
            target: sink,
            sessionId: MCPSessionId("session-1")
        )

        await emitter.emit(progress: 0.5)
        await emitter.emit(progress: 1.0, total: 1.0, message: "done")

        let count = await sink.count()
        XCTAssertEqual(count, 0)
    }

    func testEmitWithProgressTokenSendsNotification() async {
        let sink = StubProgressSink()
        let token = JsonValue.string("progress-token-1")
        let emitter = MCPProgressEmitter(
            progressToken: token,
            target: sink,
            sessionId: MCPSessionId("session-2")
        )

        await emitter.emit(progress: 0.42)

        let notifications = await sink.notifications
        XCTAssertEqual(notifications.count, 1)

        guard let first = notifications.first else {
            XCTFail("Expected at least one notification")
            return
        }
        XCTAssertEqual(first.notification.method, "notifications/progress")
        XCTAssertEqual(first.sessionId, MCPSessionId("session-2"))

        guard case .object(let params) = first.notification.params else {
            XCTFail("Expected object params")
            return
        }
        XCTAssertEqual(params["progressToken"], token)
        XCTAssertEqual(params["progress"], .double(0.42))
        XCTAssertNil(params["total"])
        XCTAssertNil(params["message"])
    }

    func testEmitIncludesTotalAndMessageWhenProvided() async {
        let sink = StubProgressSink()
        let token = JsonValue.int(123)
        let emitter = MCPProgressEmitter(
            progressToken: token,
            target: sink,
            sessionId: MCPSessionId("session-3")
        )

        await emitter.emit(progress: 5.0, total: 10.0, message: "halfway there")

        let notifications = await sink.notifications
        XCTAssertEqual(notifications.count, 1)
        guard let first = notifications.first,
              case .object(let params) = first.notification.params else {
            XCTFail("Expected notification with object params")
            return
        }
        XCTAssertEqual(params["progressToken"], token)
        XCTAssertEqual(params["progress"], .double(5.0))
        XCTAssertEqual(params["total"], .double(10.0))
        XCTAssertEqual(params["message"], .string("halfway there"))
    }

    func testMultipleEmitsQueueInOrder() async {
        let sink = StubProgressSink()
        let token = JsonValue.string("queue-token")
        let emitter = MCPProgressEmitter(
            progressToken: token,
            target: sink,
            sessionId: MCPSessionId("session-4")
        )

        await emitter.emit(progress: 0.1)
        await emitter.emit(progress: 0.2)
        await emitter.emit(progress: 0.3, message: "third")

        let notifications = await sink.notifications
        XCTAssertEqual(notifications.count, 3)

        XCTAssertEqual(progressValue(in: notifications[0].notification), 0.1)
        XCTAssertEqual(progressValue(in: notifications[1].notification), 0.2)
        XCTAssertEqual(progressValue(in: notifications[2].notification), 0.3)
        XCTAssertEqual(messageValue(in: notifications[2].notification), "third")
    }

    func testEmitNotificationSendsCustomMethod() async {
        let sink = StubProgressSink()
        let emitter = MCPProgressEmitter(
            progressToken: nil,
            target: sink,
            sessionId: MCPSessionId("session-5")
        )

        await emitter.emitNotification(method: "custom/event", params: .object(["x": .int(1)]))

        let notifications = await sink.notifications
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.notification.method, "custom/event")
    }

    func testHasProgressTokenReflectsState() async {
        let sink = StubProgressSink()
        let withToken = MCPProgressEmitter(
            progressToken: .string("t"),
            target: sink,
            sessionId: MCPSessionId("s")
        )
        let withoutToken = MCPProgressEmitter(
            progressToken: nil,
            target: sink,
            sessionId: MCPSessionId("s")
        )

        let hasA = await withToken.hasProgressToken
        let hasB = await withoutToken.hasProgressToken

        XCTAssertTrue(hasA)
        XCTAssertFalse(hasB)
    }

    func testExtractProgressTokenReadsMetaField() {
        let params: JsonValue = .object([
            "_meta": .object(["progressToken": .string("abc-123")])
        ])

        let token = MCPProgressEmitter.extractProgressToken(from: params)
        XCTAssertEqual(token, .string("abc-123"))
    }

    func testExtractProgressTokenReturnsNilWhenAbsent() {
        let withoutMeta: JsonValue = .object(["foo": .int(1)])
        let withMetaButNoToken: JsonValue = .object(["_meta": .object([:])])

        XCTAssertNil(MCPProgressEmitter.extractProgressToken(from: withoutMeta))
        XCTAssertNil(MCPProgressEmitter.extractProgressToken(from: withMetaButNoToken))
        XCTAssertNil(MCPProgressEmitter.extractProgressToken(from: nil))
    }

    private func progressValue(in notification: JsonRpcNotification) -> Double? {
        guard case .object(let params) = notification.params else { return nil }
        return params["progress"]?.doubleValue
    }

    private func messageValue(in notification: JsonRpcNotification) -> String? {
        guard case .object(let params) = notification.params else { return nil }
        return params["message"]?.stringValue
    }
}
