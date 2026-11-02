import Foundation
import TableProMemcachedCore
import Testing

struct MemcachedReplyReaderTests {
    private func read(_ shape: MemcachedReplyShape, _ chunks: [String], lineLimit: Int = .max) throws -> MemcachedReply? {
        var reader = MemcachedReplyReader(shape: shape, lineLimit: lineLimit)
        var reply: MemcachedReply?
        for chunk in chunks {
            reader.append(Array(chunk.utf8))
            reply = try reader.reply()
        }
        return reply
    }

    @Test("Values split across reads, with a CRLF inside the data, come back whole")
    func valuesAcrossChunks() throws {
        let reply = try read(.values, ["VALUE a 5 4\r\nx\r", "\ny\r\nVALUE b 0 0 7\r\n\r\nEN", "D\r\n"])
        #expect(reply == .values([
            MemcachedValue(key: "a", flags: 5, data: Data("x\r\ny".utf8)),
            MemcachedValue(key: "b", flags: 0, data: Data(), unique: 7),
        ]))
    }

    @Test("A reply missing its END is not whole yet")
    func waitsForEnd() throws {
        #expect(try read(.values, ["VALUE a 0 1\r\nx\r\n"]) == nil)
        #expect(try read(.lines, ["STAT pid 1\r\n"]) == nil)
    }

    @Test("Stats lines, and the OK some servers send before a metadump, are read up to END")
    func lines() throws {
        #expect(try read(.lines, ["STAT pid 1\r\nSTAT uptime 20\r\nEND\r\n"])
            == .lines(["STAT pid 1", "STAT uptime 20"], truncated: false))
        #expect(try read(.lines, ["OK\r\nkey=a exp=-1\r\nEND\r\n"]) == .lines(["key=a exp=-1"], truncated: false))
    }

    @Test("A metadump ends its key lines with a bare LF and only END with CRLF")
    func metadumpLineEndings() throws {
        #expect(try read(.lines, ["OK\r\nkey=a exp=-1 \nkey=b", " exp=-1 \nEND\r\n"])
            == .lines(["key=a exp=-1 ", "key=b exp=-1 "], truncated: false))
    }

    @Test("The line limit stops a long listing early and says so")
    func lineLimit() throws {
        #expect(try read(.lines, ["key=a\r\nkey=b\r\nkey=c\r\n"], lineLimit: 2) == .lines(["key=a", "key=b"], truncated: true))
    }

    @Test("Error lines throw with the server's message", arguments: [
        ("ERROR\r\n", MemcachedServerError(kind: .error, message: "")),
        ("CLIENT_ERROR unauthenticated\r\n", MemcachedServerError(kind: .clientError, message: "unauthenticated")),
        ("SERVER_ERROR out of memory storing object\r\n", MemcachedServerError(
            kind: .serverError, message: "out of memory storing object"
        )),
        ("CLIENT_ERROR lru crawler disabled\r\n", MemcachedServerError(kind: .clientError, message: "lru crawler disabled")),
    ])
    func errors(line: String, expected: MemcachedServerError) {
        #expect(throws: expected) { try read(.lines, [line]) }
    }

    @Test("An unauthenticated refusal is recognized")
    func needsAuthentication() {
        #expect(MemcachedServerError(kind: .clientError, message: "unauthenticated").needsAuthentication)
        #expect(!MemcachedServerError(kind: .clientError, message: "bad data chunk").needsAuthentication)
    }

    @Test("A status reply is its one line")
    func status() throws {
        #expect(try read(.status, ["STO", "RED\r\n"]) == .status("STORED"))
        #expect(try read(.status, ["VERSION 1.6.45\r\n"]) == .status("VERSION 1.6.45"))
    }

    @Test("A malformed VALUE header, or one announcing more than memcached can store, is a protocol error", arguments: [
        "VALUE a x 1\r\n", "VALUE a 0 9223372036854775807\r\n", "VALUE a 0 -1\r\n",
    ])
    func malformedHeader(header: String) {
        #expect(throws: MemcachedProtocolError.self) { try read(.values, [header]) }
    }
}
