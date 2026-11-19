import Foundation
import TableProKafkaCore
import Testing

struct KafkaFrameSplitterTests {
    // Feeds `stream` in `chunk`-sized arrivals the way a socket does, and returns what the splitter made of it.
    private func split(_ stream: [UInt8], chunk: Int, limit: Int) throws -> (replies: [[UInt8]], refused: [Int], peakHeld: Int) {
        var splitter = KafkaFrameSplitter()
        var held: [UInt8] = []
        var replies: [[UInt8]] = []
        var refused: [Int] = []
        var peakHeld = 0
        var arrived = 0
        repeat {
            let next = min(arrived + chunk, stream.count)
            held += stream[arrived ..< next]
            arrived = next
            peakHeld = max(peakHeld, held.count)
            drain: while true {
                let announced = held.count >= 4
                    ? held.prefix(4).reduce(Int32(0)) { ($0 << 8) | Int32($1) }
                    : nil
                switch try splitter.next(readable: held.count, announcedLength: announced, limit: limit) {
                case .needMoreData:
                    break drain
                case .skip(let count):
                    held.removeFirst(count)
                case .refuse(let length):
                    held.removeFirst(4)
                    refused.append(length)
                case .reply(let length):
                    replies.append(Array(held[4 ..< 4 + length]))
                    held.removeFirst(4 + length)
                }
            }
        } while arrived < stream.count
        return (replies, refused, peakHeld)
    }

    private func frame(_ body: [UInt8]) -> [UInt8] {
        var writer = KafkaProtocolWriter()
        writer.int32(Int32(body.count))
        return writer.bytes + body
    }

    @Test("Replies within the limit come out whole, however the bytes arrive", arguments: [1, 3, 64])
    func repliesComeOutWhole(chunk: Int) throws {
        let stream = frame([1, 2, 3]) + frame([]) + frame([4, 5])
        let result = try split(stream, chunk: chunk, limit: 16)

        #expect(result.replies == [[1, 2, 3], [], [4, 5]])
        #expect(result.refused.isEmpty)
    }

    @Test("A reply past the limit is refused at its length and skipped, and the next reply still comes out")
    func oversizeReplyIsSkipped() throws {
        let large = [UInt8](repeating: 9, count: 4_096)
        let stream = frame(large) + frame([7])
        let result = try split(stream, chunk: 256, limit: 1_024)

        #expect(result.refused == [4_096])
        #expect(result.replies == [[7]])
        #expect(result.peakHeld <= 256 + 4)
    }

    @Test("A reply at the limit is kept")
    func replyAtTheLimitIsKept() throws {
        let body = [UInt8](repeating: 1, count: 1_024)
        #expect(try split(frame(body), chunk: 512, limit: 1_024).replies == [body])
    }

    @Test("A length no broker sends is a broken stream", arguments: [Int32(-1), Int32(256 * 1_024 * 1_024 + 1)])
    func impossibleLengthThrows(length: Int32) {
        var splitter = KafkaFrameSplitter()
        #expect(throws: KafkaError.self) {
            _ = try splitter.next(readable: 4, announcedLength: length, limit: .max)
        }
    }

    @Test("Fewer than four bytes waits for the length")
    func shortHeaderWaits() throws {
        var splitter = KafkaFrameSplitter()
        #expect(try splitter.next(readable: 3, announcedLength: nil, limit: 10) == .needMoreData)
    }
}
