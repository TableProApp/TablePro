import Foundation
@testable import TableProMCP
import Testing

struct SseEncoderDecoderTests {
    @Test func testRoundTripSingleLineFrame() async throws {
        let frame = SseFrame(event: "message", id: "1", data: "hello", retry: nil)
        let encoded = SseEncoder.encode(frame)
        let decoder = SseDecoder()
        let frames = await decoder.feed(encoded)
        #expect(frames.count == 1)
        #expect(frames.first?.event == "message")
        #expect(frames.first?.id == "1")
        #expect(frames.first?.data == "hello")
    }

    @Test func testEncodeMultiLineDataProducesMultipleDataLines() {
        let frame = SseFrame(data: "line1\nline2\nline3")
        let encoded = SseEncoder.encode(frame)
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(text.contains("data: line1\n"))
        #expect(text.contains("data: line2\n"))
        #expect(text.contains("data: line3\n"))
        #expect(text.hasSuffix("\n\n"))
    }

    @Test func testRoundTripMultiLineData() async throws {
        let frame = SseFrame(data: "alpha\nbeta\ngamma")
        let encoded = SseEncoder.encode(frame)
        let decoder = SseDecoder()
        let frames = await decoder.feed(encoded)
        #expect(frames.count == 1)
        #expect(frames.first?.data == "alpha\nbeta\ngamma")
    }

    @Test func testDecodesMultipleFramesInOneChunk() async throws {
        let frameA = SseEncoder.encode(SseFrame(event: "a", data: "first"))
        let frameB = SseEncoder.encode(SseFrame(event: "b", data: "second"))
        var combined = Data()
        combined.append(frameA)
        combined.append(frameB)

        let decoder = SseDecoder()
        let frames = await decoder.feed(combined)
        #expect(frames.count == 2)
        #expect(frames[0].data == "first")
        #expect(frames[1].data == "second")
    }

    @Test func testBuffersPartialFramesAcrossChunks() async throws {
        let frame = SseFrame(event: "ping", data: "hello world")
        let encoded = SseEncoder.encode(frame)

        let split = encoded.count / 2
        let firstPart = encoded.prefix(split)
        let secondPart = encoded.suffix(from: split)

        let decoder = SseDecoder()
        let firstFrames = await decoder.feed(Data(firstPart))
        #expect(firstFrames.isEmpty)
        let secondFrames = await decoder.feed(Data(secondPart))
        #expect(secondFrames.count == 1)
        #expect(secondFrames.first?.data == "hello world")
    }

    @Test func testDecoderToleratesCrlfFieldSeparators() async throws {
        let raw = "event: x\r\nid: 7\r\ndata: hi\r\n\r\n"
        let decoder = SseDecoder()
        let frames = await decoder.feed(Data(raw.utf8))
        #expect(frames.count == 1)
        #expect(frames.first?.event == "x")
        #expect(frames.first?.id == "7")
        #expect(frames.first?.data == "hi")
    }

    @Test func testDecoderJoinsMultipleDataFieldsWithNewline() async throws {
        let raw = "data: a\ndata: b\ndata: c\n\n"
        let decoder = SseDecoder()
        let frames = await decoder.feed(Data(raw.utf8))
        #expect(frames.count == 1)
        #expect(frames.first?.data == "a\nb\nc")
    }

    @Test func testDecoderIgnoresCommentLines() async throws {
        let raw = ": this is a comment\ndata: payload\n\n"
        let decoder = SseDecoder()
        let frames = await decoder.feed(Data(raw.utf8))
        #expect(frames.count == 1)
        #expect(frames.first?.data == "payload")
    }

    @Test func testEncoderIncludesRetry() {
        let frame = SseFrame(data: "ping", retry: 5_000)
        let encoded = SseEncoder.encode(frame)
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(text.contains("retry: 5000\n"))
    }

    @Test func testEncoderEndsWithDoubleNewline() {
        let frame = SseFrame(data: "x")
        let encoded = SseEncoder.encode(frame)
        #expect(encoded.suffix(2) == Data([0x0A, 0x0A]))
    }

    @Test func testEncoderOmitsEventAndIdWhenAbsent() {
        let encoded = SseEncoder.encode(SseFrame(data: "payload"))
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(text == "data: payload\n\n")
    }

    @Test func testEncoderSplitsCrlfInsideDataIntoTwoDataLines() {
        let encoded = SseEncoder.encode(SseFrame(data: "first\r\nsecond"))
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(text == "data: first\ndata: second\n\n")
    }

    @Test func testCrlfInsideDataSurvivesAsALineBreakThroughARoundTrip() async {
        let encoded = SseEncoder.encode(SseFrame(data: "first\r\nsecond"))
        let decoder = SseDecoder()
        let frames = await decoder.feed(encoded)
        #expect(frames.count == 1)
        #expect(frames.first?.data == "first\nsecond")
    }

    @Test("A keep-alive comment alone, or a frame without data, emits nothing", arguments: [":\r\n", "event: ping\n\n"])
    func testNothingToEmit(_ stream: String) async {
        let decoder = SseDecoder()
        let frames = await decoder.feed(Data(stream.utf8))
        #expect(frames.isEmpty)
    }

    @Test func testKeepAliveCommentsBetweenFramesAreIgnored() async {
        var stream = Data(":\r\n".utf8)
        stream.append(SseEncoder.encode(SseFrame(data: "one")))
        stream.append(Data(":\r\n".utf8))
        stream.append(SseEncoder.encode(SseFrame(data: "two")))

        let decoder = SseDecoder()
        let frames = await decoder.feed(stream)
        #expect(frames.map(\.data) == ["one", "two"])
    }

    @Test func testUnknownFieldsAreIgnored() async {
        let decoder = SseDecoder()
        let frames = await decoder.feed(Data("unknown: 1\ndata: payload\n\n".utf8))
        #expect(frames.count == 1)
        #expect(frames.first?.data == "payload")
    }

    @Test func testAJsonRpcResponseTravelsAsASingleDataLine() async throws {
        let message = JsonRpcMessage.successResponse(
            JsonRpcSuccessResponse(id: .number(1), result: .object(["ok": .bool(true)]))
        )
        let payload = try #require(String(data: try JsonRpcCodec.encode(message), encoding: .utf8))
        let encoded = SseEncoder.encode(SseFrame(data: payload))
        #expect(String(data: encoded, encoding: .utf8) == "data: \(payload)\n\n")

        let decoder = SseDecoder()
        let frames = await decoder.feed(encoded)
        #expect(frames.count == 1)
        #expect(try JsonRpcCodec.decode(Data((frames.first?.data ?? "").utf8)) == message)
    }
}
