import Foundation
import TableProMemcachedCore
import Testing

struct MemcachedItemEditTests {
    private func write(value: Bool = false, flags: Bool = false, ttl: Bool = false, unique: UInt64?) -> MemcachedItemEdit? {
        MemcachedItemEdit.write(editsValue: value, editsFlags: flags, editsTTL: ttl, unique: unique)
    }

    @Test("A Flags edit carries the loaded Value and a Value edit the loaded Flags, so each is a cas on the read's unique")
    func keepingALoadedFieldIsACompareAndSwap() {
        #expect(write(flags: true, unique: 42) == .compareAndSwap(unique: 42))
        #expect(write(flags: true, ttl: true, unique: 42) == .compareAndSwap(unique: 42))
        #expect(write(value: true, unique: 42) == .compareAndSwap(unique: 42))
        #expect(write(value: true, ttl: true, unique: 42) == .compareAndSwap(unique: 42))
    }

    @Test("Without a unique from the read, an edit that keeps a loaded field asks for a refresh")
    func keepingALoadedFieldWithoutAUniqueNeedsARefresh() {
        #expect(write(flags: true, unique: nil) == .needsRefresh)
        #expect(write(value: true, ttl: true, unique: nil) == .needsRefresh)
    }

    @Test("An edit that writes both Value and Flags is a set, a TTL alone a touch, and nothing stored is no write")
    func writesThatKeepNothingLoaded() {
        #expect(write(value: true, flags: true, unique: nil) == .set)
        #expect(write(value: true, flags: true, ttl: true, unique: 42) == .set)
        #expect(write(ttl: true, unique: nil) == .touch)
        #expect(write(ttl: true, unique: 42) == .touch)
        #expect(write(unique: 42) == nil)
    }

    @Test("A cas answered EXISTS changed since the read and NOT_FOUND is gone; STORED and other commands' replies pass")
    func compareAndSwapReplies() {
        let cas = MemcachedCommand.compareAndSwap(key: "k", flags: 0, exptime: 0, unique: 7, value: Data("v".utf8))
        #expect(MemcachedCASRefusal(replyTo: cas, status: "EXISTS") == .changed)
        #expect(MemcachedCASRefusal(replyTo: cas, status: "NOT_FOUND") == .notFound)
        #expect(MemcachedCASRefusal(replyTo: cas, status: "STORED") == nil)
        #expect(MemcachedCASRefusal(replyTo: .touch(key: "k", exptime: 0), status: "NOT_FOUND") == nil)
        #expect(MemcachedCASRefusal(replyTo: .delete(key: "k"), status: "NOT_FOUND") == nil)
        #expect(MemcachedCASRefusal(
            replyTo: .store(.add, key: "k", flags: 0, exptime: 0, value: Data()), status: "EXISTS"
        ) == nil)
    }

    @Test("A cas statement parses back into its command and sends the unique after the byte count")
    func compareAndSwapStatement() throws {
        let command = try MemcachedCommandParser.parse(
            MemcachedStatements.cas(key: "k", flags: 7, exptime: 60, unique: 9_000_000_000, value: "hello")
        )
        #expect(command == .compareAndSwap(key: "k", flags: 7, exptime: 60, unique: 9_000_000_000, value: Data("hello".utf8)))
        #expect(String(bytes: command.wireBytes, encoding: .utf8) == "cas k 7 60 5 9000000000\r\nhello\r\n")

        let bytes = Data([0x00, 0xFF, 0x22, 0x0A])
        #expect(try MemcachedCommandParser.parse(
            MemcachedStatements.cas(key: "user'1", flags: 0, exptime: 0, unique: 1, bytes: bytes)
        ) == .compareAndSwap(key: "user'1", flags: 0, exptime: 0, unique: 1, value: bytes))
    }
}
