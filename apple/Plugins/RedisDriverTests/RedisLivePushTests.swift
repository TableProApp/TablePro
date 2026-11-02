import Foundation
import TableProPluginKit
import Testing

struct RedisLivePushTests {
    private static let now = Date(timeIntervalSince1970: 0)

    @Test("Channels and patterns go out as SUBSCRIBE and PSUBSCRIBE")
    func subscribeCommands() {
        let commands = RedisLivePush.subscribeCommands(
            for: PluginLiveSubscriptionRequest(channels: ["a", "b"], patterns: ["news.*"])
        )
        let text = commands.map { $0.map { String(decoding: $0, as: UTF8.self) } }
        #expect(text == [["SUBSCRIBE", "a", "b"], ["PSUBSCRIBE", "news.*"]])
    }

    @Test("A message and a pattern message become live messages; a confirmation does not")
    func parsesPushReplies() throws {
        let message = try RedisLivePush.message(
            from: .array([.data(Data("message".utf8)), .data(Data("a".utf8)), .data(Data("hi".utf8))]),
            receivedAt: Self.now
        )
        #expect(message == PluginLiveMessage(timestamp: Self.now, channel: "a", payload: "hi"))

        let patterned = try RedisLivePush.message(
            from: .array([.string("pmessage"), .string("news.*"), .string("news.eu"), .string("x")]),
            receivedAt: Self.now
        )
        #expect(patterned?.channel == "news.eu")
        #expect(patterned?.pattern == "news.*")

        let confirmation = try RedisLivePush.message(
            from: .array([.string("subscribe"), .string("a"), .integer(1)]),
            receivedAt: Self.now
        )
        #expect(confirmation == nil)
    }

    @Test("An error reply ends the read with the server's message")
    func errorReplyThrows() {
        #expect(throws: RedisPluginError.self) {
            _ = try RedisLivePush.message(from: .error("NOPERM no access"), receivedAt: Self.now)
        }
    }
}
