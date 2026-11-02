import Foundation
import TableProMCP
import Testing

struct SseDecoderChunkingTests {
    private static func decode(_ chunks: [Data]) async -> [SseFrame] {
        let decoder = SseDecoder()
        var frames: [SseFrame] = []
        for chunk in chunks {
            frames.append(contentsOf: await decoder.feed(chunk))
        }
        return frames
    }

    private static func chunks(of stream: Data, size: Int) -> [Data] {
        stride(from: 0, to: stream.count, by: size).map { stream.subdata(in: $0..<min($0 + size, stream.count)) }
    }

    private static let stream = Data((
        "event: a\r\ndata: one\r\n\r\n"
            + "data: two\rdata: three\r\r"
            + "id: 9\ndata: four\n\n"
    ).utf8)

    private static let expectedFrames = [
        SseFrame(event: "a", data: "one"),
        SseFrame(data: "two\nthree"),
        SseFrame(id: "9", data: "four")
    ]

    @Test("CRLF, CR and LF each end a line")
    func readsEveryLineEnding() async {
        #expect(await Self.decode([Self.stream]) == Self.expectedFrames)
    }

    @Test("A split at any byte, inside a CRLF included, gives the same frames")
    func everySplitPointGivesTheSameFrames() async {
        for split in 0...Self.stream.count {
            let frames = await Self.decode([
                Self.stream.subdata(in: 0..<split),
                Self.stream.subdata(in: split..<Self.stream.count)
            ])
            #expect(frames == Self.expectedFrames, "split at \(split)")
        }
    }

    @Test("Chunks of every small size give the same frames", arguments: 1...8)
    func everyChunkSizeGivesTheSameFrames(size: Int) async {
        #expect(await Self.decode(Self.chunks(of: Self.stream, size: size)) == Self.expectedFrames)
    }

    @Test("A CRLF split between two chunks is one line break, not two")
    func crlfAcrossChunksIsOneBreak() async {
        let frames = await Self.decode([Data("data: a\r".utf8), Data("\ndata: b\n\n".utf8)])
        #expect(frames == [SseFrame(data: "a\nb")])
    }

    // Rescanning the buffer from its start on every chunk makes thousands of passes over megabytes
    // here. Resuming where the last search stopped reads each byte once, well inside the limit.
    @Test("A long data line arriving in many small chunks is scanned once")
    func longLineInSmallChunksStaysLinear() async {
        let payloadLength = 2 << 20
        var stream = Data("data: ".utf8)
        stream.append(Data(repeating: 0x78, count: payloadLength))
        stream.append(Data("\n\n".utf8))
        let chunks = Self.chunks(of: stream, size: 512)

        let decoder = SseDecoder()
        var frames: [SseFrame] = []
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        for chunk in chunks where clock.now < deadline {
            frames.append(contentsOf: await decoder.feed(chunk))
        }

        #expect(clock.now < deadline, "decoding one long line in small chunks did not stay linear")
        #expect(frames.count == 1)
        #expect(frames.first?.data.utf8.count == payloadLength)
    }
}
