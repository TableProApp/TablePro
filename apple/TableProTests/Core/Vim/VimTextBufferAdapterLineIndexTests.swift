import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTextEngine
import Testing

private let lineIndexDocuments = [
    "",
    "SELECT 1",
    "a\nb\n",
    "\n",
    "\n\n",
    "a\n\n\nb\n\n",
    "line one\r\nline two\r\n\r\nline four",
    "a\r\n",
    "\r\n\r\n",
    "a\r\nb\nc\r\n\nd",
    "x\u{1F600}y\n\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} z\ne\u{301}\n\u{1F600}",
    "\tindent\n\t\tmore\n  spaces\t\n\t",
]

@MainActor
struct VimTextBufferAdapterLineIndexTests {
    private final class StubDelegate: TextViewDelegate {}

    private func makeTextView(string: String, layingOut: Bool = true) -> TextView {
        let textView = TextView(
            string: string,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            textColor: .labelColor,
            lineHeightMultiplier: 1.0,
            wrapLines: false,
            isEditable: true,
            isSelectable: true,
            letterSpacing: 1.0,
            delegate: StubDelegate()
        )
        textView.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
        if layingOut {
            textView.layout()
        }
        return textView
    }

    // MARK: - Same answers as the line walk

    @Test("Line queries answer as the line walk does", arguments: lineIndexDocuments)
    func freshDocumentMatchesTheLineWalk(text: String) {
        let textView = makeTextView(string: text)
        let adapter = VimTextBufferAdapter(textView: textView)

        let mismatches = withExtendedLifetime(textView) { Self.mismatches(adapter, against: textView.string as NSString) }

        #expect(mismatches.isEmpty, "\(mismatches.prefix(8))")
    }

    @Test("Line queries answer as the line walk does after each of a run of edits")
    func editsKeepLineQueriesInStep() {
        let textView = makeTextView(string: "SELECT 1\nFROM t\r\n\nWHERE a = 1\n")
        let adapter = VimTextBufferAdapter(textView: textView)
        let replacements = ["", "", "a", "xy", "\n", "\r", "\r\n", "\n\n", "q\nr\r\ns", "\u{1F600}", "\t", "--\n"]
        var generator = SeededGenerator(seed: 0x51DE)
        var mismatches: [String] = []

        withExtendedLifetime(textView) {
            for step in 0..<60 {
                let text = textView.string as NSString
                // Edits land on character boundaries, as the editor's own do, so none leaves half a surrogate pair.
                let start = Self.characterBoundary(Int.random(in: 0...text.length, using: &generator), in: text)
                let end = max(
                    start,
                    Self.characterBoundary(min(text.length, start + Int.random(in: 0...6, using: &generator)), in: text)
                )
                let replacement = replacements.randomElement(using: &generator) ?? ""
                textView.replaceCharacters(in: NSRange(location: start, length: end - start), with: replacement)
                // The editor drops the adapter's cache on every edit.
                adapter.invalidateLineCache()

                let edited = textView.string as NSString
                mismatches += Self.mismatches(adapter, against: edited).map {
                    "step \(step) \(String(reflecting: edited as String)): \($0)"
                }
            }
        }

        #expect(mismatches.isEmpty, "\(mismatches.prefix(8))")
    }

    @Test("Line queries walk the text while the line storage still describes the text before an edit", arguments: [
        ("a\nb\r\nc\n", NSRange(location: 2, length: 0), "x\n\ny\r\n"),
        ("one\ntwo\nthree", NSRange(location: 0, length: 4), ""),
        ("SELECT 1\r\n\r\nSELECT 2", NSRange(location: 10, length: 2), "--\n"),
    ])
    func staleLineStorageFallsBackToTheText(original: String, range: NSRange, replacement: String) {
        let textView = makeTextView(string: original)
        let adapter = VimTextBufferAdapter(textView: textView)

        withExtendedLifetime(textView) {
            textView.layoutManager.processesEdits = false
            textView.textStorage.replaceCharacters(in: range, with: replacement)
            #expect(textView.layoutManager.lineStorage.length != textView.textStorage.length)

            let stale = Self.mismatches(adapter, against: textView.string as NSString)
            #expect(stale.isEmpty, "\(stale.prefix(8))")

            textView.layoutManager.processesEdits = true
            textView.layoutManager.reset()
            let rebuilt = Self.mismatches(adapter, against: textView.string as NSString)
            #expect(rebuilt.isEmpty, "\(rebuilt.prefix(8))")
        }
    }

    // The line walk this replaced counted only line feeds for `lineAndColumn`, while `lineRange` and
    // `offset(forLine:column:)` also break at a lone carriage return. Every query now numbers lines the same way.
    @Test("A lone carriage return ends a line for every line query", arguments: [
        "a\rb\rc",
        "a\rb\r",
        "a\r\rb\nc\r\nd",
    ])
    func carriageReturnEndsALine(text: String) {
        let textView = makeTextView(string: text)
        let adapter = VimTextBufferAdapter(textView: textView)
        let nsText = text as NSString
        var lineRanges: [NSRange] = []
        var location = 0
        while location < nsText.length {
            let range = nsText.lineRangeBreakingAtLineEndings(for: NSRange(location: location, length: 0))
            lineRanges.append(range)
            location = NSMaxRange(range)
        }

        var mismatches: [String] = []
        withExtendedLifetime(textView) {
            if adapter.lineCount != lineRanges.count {
                mismatches.append("lineCount \(adapter.lineCount), expected \(lineRanges.count)")
            }
            for (line, range) in lineRanges.enumerated() {
                if adapter.offset(forLine: line, column: 0) != range.location {
                    mismatches.append("offset(forLine: \(line)) \(adapter.offset(forLine: line, column: 0))")
                }
                for offset in range.location..<NSMaxRange(range) {
                    let position = adapter.lineAndColumn(forOffset: offset)
                    if position != (line, offset - range.location) {
                        mismatches.append("lineAndColumn(\(offset)) \(position), expected line \(line)")
                    }
                }
            }
        }

        #expect(mismatches.isEmpty, "\(mismatches.prefix(8))")
    }

    // MARK: - Cost per line

    // A fixed time limit cannot tell a slow runner from a slow motion, so the motion is timed against itself. Sixteen
    // passes over a script and four over one four times as long visit the same number of lines. When each line costs
    // the same the two take as long; when finding a line walks the lines before it, the long script takes four times
    // as long, so a bound of twice sits a factor of two from each. The fastest of three drops the samples a stall
    // landed on.
    @Test("]] costs as much per line in a long script as in a short one")
    func sectionForwardStaysLinear() {
        let short = makeSectionScript(lines: 500)
        let long = makeSectionScript(lines: 2_000)

        var shortLanding = 0
        var longLanding = 0
        var shortPasses = TimeInterval.infinity
        var longPasses = TimeInterval.infinity
        withExtendedLifetime((short.textView, long.textView)) {
            for _ in 0..<3 {
                shortPasses = min(shortPasses, Self.secondsSpent {
                    for _ in 0..<16 {
                        shortLanding = Self.pressSectionForward(short.engine, short.adapter)
                    }
                })
                longPasses = min(longPasses, Self.secondsSpent {
                    for _ in 0..<4 {
                        longLanding = Self.pressSectionForward(long.engine, long.adapter)
                    }
                })
            }
        }

        #expect(shortLanding == short.lastOffset)
        #expect(longLanding == long.lastOffset)
        #expect(longPasses < shortPasses * 2)
    }

    private struct SectionScript {
        let textView: TextView
        let adapter: VimTextBufferAdapter
        let engine: VimEngine
        let lastOffset: Int
    }

    // Not laid out: the motion reads only the line storage, and a text view outside a scroll view lays out every line.
    private func makeSectionScript(lines: Int) -> SectionScript {
        let script = String(repeating: "SELECT id, name FROM users WHERE id = 1;\n", count: lines)
        let textView = makeTextView(string: script, layingOut: false)
        let adapter = VimTextBufferAdapter(textView: textView)
        return SectionScript(
            textView: textView,
            adapter: adapter,
            engine: VimEngine(buffer: adapter),
            lastOffset: (script as NSString).length - 1
        )
    }

    private static func pressSectionForward(_ engine: VimEngine, _ adapter: VimTextBufferAdapter) -> Int {
        adapter.setSelectedRange(NSRange(location: 0, length: 0))
        _ = engine.process("]", shift: false)
        _ = engine.process("]", shift: false)
        return adapter.selectedRange().location
    }

    private static func secondsSpent(_ work: () -> Void) -> TimeInterval {
        let start = ProcessInfo.processInfo.systemUptime
        work()
        return ProcessInfo.processInfo.systemUptime - start
    }

    // MARK: - Comparison

    private static func characterBoundary(_ offset: Int, in text: NSString) -> Int {
        guard offset > 0, offset < text.length else { return offset }
        return text.rangeOfComposedCharacterSequence(at: offset).location
    }

    private static func mismatches(_ adapter: VimTextBufferAdapter, against text: NSString) -> [String] {
        var found: [String] = []
        if adapter.length != text.length {
            found.append("length \(adapter.length), expected \(text.length)")
        }
        let lineCount = LineWalk.lineCount(of: text)
        if adapter.lineCount != lineCount {
            found.append("lineCount \(adapter.lineCount), expected \(lineCount)")
        }
        for offset in -1...(text.length + 1) {
            let position = adapter.lineAndColumn(forOffset: offset)
            let expectedPosition = LineWalk.lineAndColumn(of: text, forOffset: offset)
            if position != expectedPosition {
                found.append("lineAndColumn(\(offset)) \(position), expected \(expectedPosition)")
            }
            let range = adapter.lineRange(forOffset: offset)
            let expectedRange = LineWalk.lineRange(of: text, forOffset: offset)
            if range != expectedRange {
                found.append("lineRange(\(offset)) \(range), expected \(expectedRange)")
            }
            if offset >= 0 && offset < text.length && adapter.character(at: offset) != text.character(at: offset) {
                found.append("character(at: \(offset)) \(adapter.character(at: offset))")
            }
        }
        for line in -1...(lineCount + 1) {
            for column in [-1, 0, 1, 2, 5, 1_000] {
                let offset = adapter.offset(forLine: line, column: column)
                let expectedOffset = LineWalk.offset(of: text, forLine: line, column: column)
                if offset != expectedOffset {
                    found.append("offset(forLine: \(line), column: \(column)) \(offset), expected \(expectedOffset)")
                }
            }
        }
        return found
    }

}

// The line walk `VimTextBufferAdapter` used before it read the layout manager's line storage, kept as the reference
// its answers are compared with. `lineAndColumn` counts every line break here, as the other queries always did; the
// old one counted only line feeds, which `carriageReturnEndsALine` covers.
private enum LineWalk {
    static func lineCount(of text: NSString) -> Int {
        if text.length == 0 { return 1 }
        var count = 0
        var index = 0
        while index < text.length {
            let lineRange = text.lineRangeBreakingAtLineEndings(for: NSRange(location: index, length: 0))
            count += 1
            index = lineRange.location + lineRange.length
        }
        return max(1, count)
    }

    static func lineRange(of text: NSString, forOffset offset: Int) -> NSRange {
        let clampedOffset = min(max(0, offset), text.length)
        return text.lineRangeBreakingAtLineEndings(for: NSRange(location: clampedOffset, length: 0))
    }

    static func lineAndColumn(of text: NSString, forOffset offset: Int) -> (line: Int, column: Int) {
        let clampedOffset = min(max(0, offset), text.length)
        if text.length == 0 { return (0, 0) }
        let safeOffset = min(clampedOffset, max(0, text.length - 1))
        let lineRange = text.lineRangeBreakingAtLineEndings(for: NSRange(location: safeOffset, length: 0))
        var line = 0
        var index = 0
        while index < lineRange.location {
            index = NSMaxRange(text.lineRangeBreakingAtLineEndings(for: NSRange(location: index, length: 0)))
            line += 1
        }
        return (line, clampedOffset - lineRange.location)
    }

    static func offset(of text: NSString, forLine line: Int, column: Int) -> Int {
        var currentLine = 0
        var index = 0
        while index < text.length && currentLine < line {
            let lineRange = text.lineRangeBreakingAtLineEndings(for: NSRange(location: index, length: 0))
            currentLine += 1
            index = lineRange.location + lineRange.length
        }
        let lineRange = text.lineRangeBreakingAtLineEndings(for: NSRange(location: min(index, text.length), length: 0))
        let contentLength: Int
        let lineEnd = lineRange.location + lineRange.length
        if lineEnd > lineRange.location && lineEnd <= text.length && text.character(at: lineEnd - 1) == 0x0A {
            contentLength = lineRange.length - 1
        } else {
            contentLength = lineRange.length
        }
        let clampedCol = min(column, max(0, contentLength - 1))
        return lineRange.location + max(0, clampedCol)
    }
}
