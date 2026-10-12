import Foundation
@testable import TableProMobile

actor ScriptedRedisServer {
    struct ScriptExhausted: Error {}

    private var replies: [RedisReplyValue]
    private let repeatsLastReply: Bool
    private let replyForRequest: (@Sendable (_ requestIndex: Int) -> RedisReplyValue)?
    private(set) var sent: [[String]] = []

    init(replies: [RedisReplyValue], repeatsLastReply: Bool = false) {
        self.replies = replies
        self.repeatsLastReply = repeatsLastReply
        self.replyForRequest = nil
    }

    init(replyingTo replyForRequest: @escaping @Sendable (_ requestIndex: Int) -> RedisReplyValue) {
        self.replies = []
        self.repeatsLastReply = false
        self.replyForRequest = replyForRequest
    }

    func reply(to arguments: [String]) throws -> RedisReplyValue {
        sent.append(arguments)
        if let replyForRequest {
            return replyForRequest(sent.count - 1)
        }
        guard let next = replies.first else { throw ScriptExhausted() }
        if replies.count > 1 || !repeatsLastReply {
            replies.removeFirst()
        }
        return next
    }
}

func scanReply(cursor: String, keys: [String]) -> RedisReplyValue {
    .array([.string(cursor), .array(keys.map { .string($0) })])
}
