import CRedis
import Foundation
@testable import TableProMobile
import Testing

struct HiredisReplyTests {
    private static func convert(_ wire: String) throws -> RedisReplyValue {
        let reader = try #require(redisReaderCreate())
        defer { redisReaderFree(reader) }
        #expect(redisReaderFeed(reader, wire, wire.utf8.count) == REDIS_OK)
        var raw: UnsafeMutableRawPointer?
        #expect(redisReaderGetReply(reader, &raw) == REDIS_OK)
        let reply = try #require(raw)
        defer { HiredisReply.release(reply) }
        return HiredisReply.value(of: reply.assumingMemoryBound(to: redisReply.self))
    }

    private static func firstElementChain(_ reply: RedisReplyValue) -> (depth: Int, innermost: RedisReplyValue) {
        var depth = 0
        var current = reply
        while case .array(let items) = current, let first = items.first {
            depth += 1
            current = first
        }
        return (depth, current)
    }

    @Test("A reply nested deeper than the cap ends in a placeholder and is freed without recursing per level")
    func deeplyNestedReply() throws {
        let reply = try Self.convert(String(repeating: "*1\r\n", count: 20_000) + ":1\r\n")
        let chain = Self.firstElementChain(reply)
        #expect(chain.depth == HiredisReply.maximumDepth)
        #expect(chain.innermost.errorMessage != nil)
    }

    @Test("A reply nested just inside the cap reads in full")
    func replyInsideTheCap() throws {
        let depth = HiredisReply.maximumDepth - 1
        let reply = try Self.convert(String(repeating: "*1\r\n", count: depth) + ":7\r\n")
        let chain = Self.firstElementChain(reply)
        #expect(chain.depth == depth)
        #expect(chain.innermost == .integer(7))
    }

    @Test("Flat replies read as before")
    func flatReplies() throws {
        #expect(try Self.convert("*3\r\n$3\r\nfoo\r\n:42\r\n$-1\r\n") == .array([.string("foo"), .integer(42), .null]))
        #expect(try Self.convert("+OK\r\n") == .status("OK"))
        #expect(try Self.convert("-ERR boom\r\n") == .error("ERR boom"))
        #expect(try Self.convert("*0\r\n") == .array([]))
    }

    private struct Outcome: Sendable {
        let status: Int32
        let error: Int32
        let reply: RedisReplyValue?
    }

    private static let deepNesting = String(repeating: "*1\r\n", count: 20_000)

    // 512 KiB is a Dispatch worker's stack, which a free that recurses once per level overflows at this depth.
    private static func onSmallStack(
        fed wire: String,
        _ read: @escaping @Sendable (UnsafeMutablePointer<redisContext>) -> Outcome
    ) async -> Outcome? {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: Self.withConnection(fed: wire, read))
            }
            thread.stackSize = 512 * 1_024
            thread.start()
        }
    }

    private static func withConnection(
        fed wire: String,
        _ read: (UnsafeMutablePointer<redisContext>) -> Outcome
    ) -> Outcome? {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { return nil }
        // A closed peer turns any socket read into an error rather than a wait.
        close(sockets[1])
        guard let context = redisConnectFd(sockets[0]) else {
            close(sockets[0])
            return nil
        }
        defer { redisFree(context) }
        HiredisReply.installIterativeFree(on: context)
        guard redisReaderFeed(context.pointee.reader, wire, wire.utf8.count) == REDIS_OK else { return nil }
        return read(context)
    }

    @Test("A protocol error under a deeply nested partial reply fails without recursing per level")
    func protocolErrorUnderDeepReply() async throws {
        let outcome = await Self.onSmallStack(fed: Self.deepNesting + "@\r\n") { context in
            var raw: UnsafeMutableRawPointer?
            let status = redisReaderGetReply(context.pointee.reader, &raw)
            return Outcome(status: status, error: context.pointee.reader.pointee.err, reply: nil)
        }
        let read = try #require(outcome)
        #expect(read.status == REDIS_ERR)
        #expect(read.error == REDIS_ERR_PROTOCOL)
    }

    @Test("Freeing a connection that holds a deeply nested partial reply does not recurse per level")
    func freeWithDeepPartialReply() async throws {
        let outcome = await Self.onSmallStack(fed: Self.deepNesting) { context in
            var raw: UnsafeMutableRawPointer?
            let status = redisReaderGetReply(context.pointee.reader, &raw)
            return Outcome(status: status, error: context.pointee.reader.pointee.err, reply: raw.map { _ in RedisReplyValue.null })
        }
        let read = try #require(outcome)
        #expect(read.status == REDIS_OK)
        #expect(read.reply == nil)
    }

    @Test("A deeply nested RESP3 push hiredis drops is freed without recursing per level")
    func droppedDeepPush() async throws {
        let outcome = await Self.onSmallStack(fed: ">1\r\n" + Self.deepNesting + ":1\r\n+OK\r\n") { context in
            var raw: UnsafeMutableRawPointer?
            let status = redisGetReply(context, &raw)
            let value = raw.map { reply in
                defer { HiredisReply.release(reply) }
                return HiredisReply.value(of: reply.assumingMemoryBound(to: redisReply.self))
            }
            return Outcome(status: status, error: context.pointee.err, reply: value)
        }
        let read = try #require(outcome)
        #expect(read.status == REDIS_OK)
        #expect(read.reply == .status("OK"))
    }
}
