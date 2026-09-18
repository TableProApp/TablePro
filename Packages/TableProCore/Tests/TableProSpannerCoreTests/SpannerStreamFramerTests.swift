import Foundation
import Testing

@testable import TableProSpannerCore

@Suite("SpannerStreamFramer")
struct SpannerStreamFramerTests {
    private static let first = #"{"metadata":{"rowType":{"fields":[{"name":"a","type":{"code":"STRING"}}]}},"values":["x{\"}]["]}"#
    private static let second = #"{"values":["a\\"],"chunkedValue":true}"#
    private static let third = #"{"values":["}\u007b"]}"#

    private static let jsonArrayStream = "[\(first)\n,\r\n\(second),\t\(third)]"
    private static let ndjsonStream = """
    {"result":\(first)}
    {"result": \(second) }
    { "result" :\(third)}

    """

    private func frames(of text: String, splitEvery size: Int) throws -> [String] {
        var framer = SpannerStreamFramer()
        let bytes = Array(text.utf8)
        var output: [Data] = []
        var start = 0
        while start < bytes.count {
            let end = min(start + size, bytes.count)
            output.append(contentsOf: try framer.append(Data(bytes[start..<end])))
            start = end
        }
        try framer.finish()
        return output.compactMap { String(bytes: $0, encoding: .utf8) }
    }

    @Test("A JSON array stream yields each top-level object")
    func jsonArray() throws {
        #expect(try frames(of: Self.jsonArrayStream, splitEvery: Int.max) == [Self.first, Self.second, Self.third])
    }

    @Test("NDJSON with the grpc-gateway result wrapper yields the inner objects")
    func ndjson() throws {
        #expect(try frames(of: Self.ndjsonStream, splitEvery: Int.max) == [Self.first, Self.second, Self.third])
    }

    @Test("Splitting at every byte boundary yields the same frames", arguments: [1, 2, 3, 7, 64])
    func arbitrarySplits(size: Int) throws {
        #expect(try frames(of: Self.jsonArrayStream, splitEvery: size) == [Self.first, Self.second, Self.third])
        #expect(try frames(of: Self.ndjsonStream, splitEvery: size) == [Self.first, Self.second, Self.third])
    }

    @Test("A multi-byte character split across chunks survives")
    func multiByteSplit() throws {
        let object = #"{"values":["héllo 世界 🎉"]}"#
        #expect(try frames(of: "[\(object)]", splitEvery: 1) == [object])
    }

    @Test("An error object passes through unwrapped for the message decoder")
    func errorPassesThrough() throws {
        let error = #"{"error":{"code":11,"message":"division by zero: 1 / 0"}}"#
        #expect(try frames(of: "\(Self.first)\n\(error)\n", splitEvery: 5) == [Self.first, error])
    }

    @Test("A result wrapper with a sibling key is not unwrapped")
    func wrapperWithSibling() throws {
        let object = #"{"result":{"values":[]},"other":{"x":1}}"#
        #expect(try frames(of: object, splitEvery: Int.max) == [object])
    }

    @Test("A truncated object fails on finish")
    func truncated() throws {
        var framer = SpannerStreamFramer()
        #expect(try framer.append(Data(#"[{"values":["abc"#.utf8)).isEmpty)
        #expect(throws: SpannerTransportError.invalidResponse) {
            try framer.finish()
        }
    }

    @Test("Garbage between objects is refused")
    func garbage() {
        var framer = SpannerStreamFramer()
        #expect(throws: SpannerTransportError.invalidResponse) {
            _ = try framer.append(Data("<html>".utf8))
        }
    }

    @Test("An empty JSON array yields nothing and finishes cleanly")
    func emptyArray() throws {
        #expect(try frames(of: "[]\n", splitEvery: 1).isEmpty)
    }

    @Test("Frames decode into partial results and in-stream failures")
    func messageDecoding() throws {
        let partial = try SpannerStreamMessage.decode(Data(Self.second.utf8), httpStatus: 200)
        guard case .partial(let set) = partial else {
            Issue.record("Expected a partial result set")
            return
        }
        #expect(set.values == [.string("a\\")])
        #expect(set.chunkedValue)

        let wrapped = try SpannerStreamMessage.decode(
            Data(#"{"error":{"code":10,"message":"Transaction was aborted.","status":"ABORTED"}}"#.utf8),
            httpStatus: 200
        )
        guard case .failure(let error) = wrapped else {
            Issue.record("Expected an in-stream failure")
            return
        }
        #expect(error.isAborted)
        #expect(error.httpStatus == 200)

        let bare = try SpannerStreamMessage.decode(Data(#"{"code":14,"message":"unavailable"}"#.utf8), httpStatus: 200)
        guard case .failure(let bareError) = bare else {
            Issue.record("Expected a bare Status failure")
            return
        }
        #expect(bareError.isUnavailable)
    }

    @Test("A frame that is not a partial result set is an invalid response")
    func undecodableFrame() {
        #expect(throws: SpannerTransportError.invalidResponse) {
            try SpannerStreamMessage.decode(Data(#"{"values":"nope"}"#.utf8), httpStatus: 200)
        }
    }
}
