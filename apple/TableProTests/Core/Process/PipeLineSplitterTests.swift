import Foundation
@testable import TablePro
import Testing

struct PipeLineSplitterTests {
    @Test("A character split across two chunks arrives whole")
    func multibyteCharacterAcrossChunks() {
        var splitter = PipeLineSplitter()
        let bytes = Data("café\n".utf8)
        let cut = bytes.firstIndex(of: 0xC3).map { bytes.index(after: $0) } ?? bytes.endIndex

        #expect(splitter.lines(appending: bytes[..<cut]).isEmpty)
        #expect(splitter.lines(appending: bytes[cut...]) == ["café"])
    }

    @Test("CRLF and LF both end a line, and empty lines are kept")
    func lineEndings() {
        var splitter = PipeLineSplitter()
        #expect(splitter.lines(appending: Data("one\r\ntwo\n\nthree".utf8)) == ["one", "two", ""])
        #expect(splitter.finish() == "three")
        #expect(splitter.finish() == nil)
    }

    @Test("A line separator inside a JSON string does not cut the line")
    func unicodeLineSeparatorStaysInTheLine() {
        var splitter = PipeLineSplitter()
        let line = "{\"text\":\"a\u{2028}b\"}"
        #expect(splitter.lines(appending: Data((line + "\n").utf8)) == [line])
    }
}
