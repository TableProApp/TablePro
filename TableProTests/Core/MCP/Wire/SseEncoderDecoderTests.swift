import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class SseEncoderDecoderTests: XCTestCase {
    func testRoundTripSingleLineFrame() async throws {
        let frame = SseFrame(event: "message", id: "1", data: "hello", retry: nil)
        let encoded = SseEncoder.encode(frame)
        let decoder = SseDecoder()
        let frames = await decoder.feed(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.event, "message")
        XCTAssertEqual(frames.first?.id, "1")
        XCTAssertEqual(frames.first?.data, "hello")
    }

    func testEncodeMultiLineDataProducesMultipleDataLines() {
        let frame = SseFrame(data: "line1\nline2\nline3")
        let encoded = SseEncoder.encode(frame)
        let text = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("data: line1\n"))
        XCTAssertTrue(text.contains("data: line2\n"))
        XCTAssertTrue(text.contains("data: line3\n"))
        XCTAssertTrue(text.hasSuffix("\n\n"))
    }

    func testRoundTripMultiLineData() async throws {
        let frame = SseFrame(data: "alpha\nbeta\ngamma")
        let encoded = SseEncoder.encode(frame)
        let decoder = SseDecoder()
        let frames = await decoder.feed(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.data, "alpha\nbeta\ngamma")
    }

    func testDecodesMultipleFramesInOneChunk() async throws {
        let frameA = SseEncoder.encode(SseFrame(event: "a", data: "first"))
        let frameB = SseEncoder.encode(SseFrame(event: "b", data: "second"))
        var combined = Data()
        combined.append(frameA)
        combined.append(frameB)

        let decoder = SseDecoder()
        let frames = await decoder.feed(combined)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].data, "first")
        XCTAssertEqual(frames[1].data, "second")
    }

    func testBuffersPartialFramesAcrossChunks() async throws {
        let frame = SseFrame(event: "ping", data: "hello world")
        let encoded = SseEncoder.encode(frame)

        let split = encoded.count / 2
        let firstPart = encoded.prefix(split)
        let secondPart = encoded.suffix(from: split)

        let decoder = SseDecoder()
        let firstFrames = await decoder.feed(Data(firstPart))
        XCTAssertTrue(firstFrames.isEmpty)
        let secondFrames = await decoder.feed(Data(secondPart))
        XCTAssertEqual(secondFrames.count, 1)
        XCTAssertEqual(secondFrames.first?.data, "hello world")
    }

    func testDecoderToleratesCrlfFieldSeparators() async throws {
        let raw = "event: x\r\nid: 7\r\ndata: hi\r\n\r\n"
        let decoder = SseDecoder()
        let frames = await decoder.feed(Data(raw.utf8))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.event, "x")
        XCTAssertEqual(frames.first?.id, "7")
        XCTAssertEqual(frames.first?.data, "hi")
    }

    func testDecoderJoinsMultipleDataFieldsWithNewline() async throws {
        let raw = "data: a\ndata: b\ndata: c\n\n"
        let decoder = SseDecoder()
        let frames = await decoder.feed(Data(raw.utf8))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.data, "a\nb\nc")
    }

    func testDecoderIgnoresCommentLines() async throws {
        let raw = ": this is a comment\ndata: payload\n\n"
        let decoder = SseDecoder()
        let frames = await decoder.feed(Data(raw.utf8))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.data, "payload")
    }

    func testEncoderIncludesRetry() {
        let frame = SseFrame(data: "ping", retry: 5_000)
        let encoded = SseEncoder.encode(frame)
        let text = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("retry: 5000\n"))
    }

    func testEncoderEndsWithDoubleNewline() {
        let frame = SseFrame(data: "x")
        let encoded = SseEncoder.encode(frame)
        XCTAssertEqual(encoded.suffix(2), Data([0x0A, 0x0A]))
    }

    func testEncoderOmitsEventAndIdWhenAbsent() {
        let encoded = SseEncoder.encode(SseFrame(data: "payload"))
        let text = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertEqual(text, "data: payload\n\n")
    }

    func testEncoderSplitsCrlfInsideDataIntoTwoDataLines() {
        let encoded = SseEncoder.encode(SseFrame(data: "first\r\nsecond"))
        let text = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertEqual(text, "data: first\ndata: second\n\n")
    }

    func testCrlfInsideDataSurvivesAsALineBreakThroughARoundTrip() async {
        let encoded = SseEncoder.encode(SseFrame(data: "first\r\nsecond"))
        let decoder = SseDecoder()
        let frames = await decoder.feed(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.data, "first\nsecond")
    }

    func testKeepAliveCommentAloneProducesNoFrames() async {
        let decoder = SseDecoder()
        let frames = await decoder.feed(Data(":\r\n".utf8))
        XCTAssertTrue(frames.isEmpty)
    }

    func testKeepAliveCommentsBetweenFramesAreIgnored() async {
        var stream = Data(":\r\n".utf8)
        stream.append(SseEncoder.encode(SseFrame(data: "one")))
        stream.append(Data(":\r\n".utf8))
        stream.append(SseEncoder.encode(SseFrame(data: "two")))

        let decoder = SseDecoder()
        let frames = await decoder.feed(stream)
        XCTAssertEqual(frames.map(\.data), ["one", "two"])
    }

    func testUnknownFieldsAreIgnored() async {
        let decoder = SseDecoder()
        let frames = await decoder.feed(Data("unknown: 1\ndata: payload\n\n".utf8))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.data, "payload")
    }

    func testAFrameWithoutDataIsNotEmitted() async {
        let decoder = SseDecoder()
        let frames = await decoder.feed(Data("event: ping\n\n".utf8))
        XCTAssertTrue(frames.isEmpty)
    }

    func testAJsonRpcResponseTravelsAsASingleDataLine() async throws {
        let message = JsonRpcMessage.successResponse(
            JsonRpcSuccessResponse(id: .number(1), result: .object(["ok": .bool(true)]))
        )
        let payload = try XCTUnwrap(String(data: try JsonRpcCodec.encode(message), encoding: .utf8))
        let encoded = SseEncoder.encode(SseFrame(data: payload))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "data: \(payload)\n\n")

        let decoder = SseDecoder()
        let frames = await decoder.feed(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(try JsonRpcCodec.decode(Data((frames.first?.data ?? "").utf8)), message)
    }
}
