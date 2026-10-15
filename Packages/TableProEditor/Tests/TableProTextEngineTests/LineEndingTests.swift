import AppKit
@testable import TableProTextEngine
import Testing

@MainActor
struct LineEndingTests {
    @Test func test_lineEndingCreateUnix() {
        // The \n character
        #expect(LineEnding(rawValue: "\n") != nil, "Line ending failed to initialize with the \\n character")

        let line = "Loren Ipsum\n"
        #expect(LineEnding(line: line) != nil, "Line ending failed to initialize with a line ending in \\n")
    }

    @Test func test_lineEndingCreateCRLF() {
        // The \r\n sequence
        #expect(LineEnding(rawValue: "\r\n") != nil, "Line ending failed to initialize with the \\r\\n sequence")

        let line = "Loren Ipsum\r\n"
        #expect(LineEnding(line: line) != nil, "Line ending failed to initialize with a line ending in \\r\\n")
    }

    @Test func test_lineEndingCreateMacOS() {
        // The \r character
        #expect(LineEnding(rawValue: "\r") != nil, "Line ending failed to initialize with the \\r character")

        let line = "Loren Ipsum\r"
        #expect(LineEnding(line: line) != nil, "Line ending failed to initialize with a line ending in \\r")
    }

    @Test func test_detectLineEndingDefault() {
        // There was a bug in this that caused it to flake sometimes, so we run this a couple times to ensure it's not
        // flaky.
        // The odds of it being bad with the earlier bug after running 20 times is incredibly small
        for _ in 0..<20 {
            let storage = NSTextStorage(string: "hello world") // No line ending
            let lineStorage = TextLineStorage<TextLine>()
            lineStorage.buildFromTextStorage(storage, estimatedLineHeight: 10)
            let detected = LineEnding.detectLineEnding(lineStorage: lineStorage, textStorage: storage)
            #expect(detected == .lineFeed)
        }
    }

    let corpus = "abcdefghijklmnopqrstuvwxyz123456789"
    func makeRandomText(_ goalLineEnding: LineEnding) -> String {
        (10..<Int.random(in: 20..<100)).reduce(into: "") { partialResult, _ in
            partialResult += String(
                (0..<Int.random(in: 1..<20)).compactMap { _ in corpus.randomElement() }
            ) + goalLineEnding.rawValue
        }
    }

    @Test func test_detectLineEndingUnix() {
        let goalLineEnding = LineEnding.lineFeed

        let storage = NSTextStorage(string: makeRandomText(goalLineEnding))
        let lineStorage = TextLineStorage<TextLine>()
        lineStorage.buildFromTextStorage(storage, estimatedLineHeight: 10)

        let detected = LineEnding.detectLineEnding(lineStorage: lineStorage, textStorage: storage)
        #expect(detected == goalLineEnding)
    }

    @Test func test_detectLineEndingCLRF() {
        let goalLineEnding = LineEnding.carriageReturnLineFeed

        let storage = NSTextStorage(string: makeRandomText(goalLineEnding))
        let lineStorage = TextLineStorage<TextLine>()
        lineStorage.buildFromTextStorage(storage, estimatedLineHeight: 10)

        let detected = LineEnding.detectLineEnding(lineStorage: lineStorage, textStorage: storage)
        #expect(detected == goalLineEnding)
    }

    @Test func test_detectLineEndingMacOS() {
        let goalLineEnding = LineEnding.carriageReturn

        let storage = NSTextStorage(string: makeRandomText(goalLineEnding))
        let lineStorage = TextLineStorage<TextLine>()
        lineStorage.buildFromTextStorage(storage, estimatedLineHeight: 10)

        let detected = LineEnding.detectLineEnding(lineStorage: lineStorage, textStorage: storage)
        #expect(detected == goalLineEnding)
    }
}
