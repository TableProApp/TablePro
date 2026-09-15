import AppKit
import CoreText
@testable import TableProTextEngine
import Testing

/// Counts how often the renderer reaches for the document's text.
final class CountingTextStorage: NSTextStorage {
    private let backing = NSTextStorage()
    private(set) var stringAccessCount = 0

    override var string: String {
        stringAccessCount += 1
        return backing.string
    }

    func resetCount() {
        stringAccessCount = 0
    }

    override func attributes(
        at location: Int,
        effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }
}

/// Records every invisible character the renderer asks about.
final class RecordingInvisibleDelegate: InvisibleCharactersDelegate {
    var triggerCharacters: Set<UInt16>
    private(set) var requestedIndices: [Int] = []

    init(triggerCharacters: Set<UInt16>) {
        self.triggerCharacters = triggerCharacters
    }

    func invisibleStyleShouldClearCache() -> Bool { false }

    func invisibleStyle(for character: UInt16, at range: NSRange, lineRange: NSRange) -> InvisibleCharacterStyle? {
        requestedIndices.append(range.location)
        return nil
    }
}

@Suite("Line fragment renderer")
@MainActor
struct LineFragmentRendererTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let space: UInt16 = 0x20

    private var characterWidth: CGFloat {
        ("a" as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: - Helpers

    private func makeFragment(_ text: String, attachments: [AnyTextAttachment] = []) throws -> LineFragment {
        let typesetter = Typesetter()
        typesetter.typeset(
            NSAttributedString(string: text, attributes: [.font: font]),
            documentRange: NSRange(location: 0, length: (text as NSString).length),
            displayData: TextLine.DisplayData(
                maxWidth: .infinity,
                lineHeightMultiplier: 1.0,
                estimatedLineHeight: 20.0,
                breakStrategy: .character,
                specialCharacterStyle: nil
            ),
            markedRanges: nil,
            attachments: attachments
        )
        let fragment = try #require(typesetter.lineFragments.first?.data)
        fragment.documentRange = NSRange(location: 0, length: (text as NSString).length)
        return fragment
    }

    private func makeStorage(_ text: String) -> NSTextStorage {
        NSTextStorage(string: text, attributes: [.font: font])
    }

    /// A drawing context shaped like a flipped line fragment view: y grows downward and the window's top left corner
    /// lands on the bitmap's top left corner.
    private func makeContext(window: CGRect) -> CGContext? {
        let pixelWidth = Int(ceil(window.width))
        let pixelHeight = Int(ceil(window.height))
        guard pixelWidth > 0, pixelHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -window.minX, y: -window.minY)
        context.clip(to: window)
        return context
    }

    private func textLine(of fragment: LineFragment) -> CTLine? {
        for content in fragment.contents {
            if case .text(let ctLine) = content.data { return ctLine }
        }
        return nil
    }

    /// The fastest of several runs, which is the statistic that survives a loaded machine.
    private func bestSeconds(window: CGRect, iterations: Int = 7, _ body: (CGContext) -> Void) -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<iterations {
            guard let context = makeContext(window: window) else { continue }
            let start = DispatchTime.now().uptimeNanoseconds
            body(context)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            best = min(best, elapsed)
        }
        return best
    }

    private func bytes(of context: CGContext) -> [UInt8] {
        guard let data = context.data else { return [] }
        let length = context.bytesPerRow * context.height
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: length))
    }

    private func mismatchingPixels(_ lhs: [UInt8], _ rhs: [UInt8], bytesPerRow: Int, columns: Range<Int>) -> Int {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .max }
        var count = 0
        var rowStart = 0
        while rowStart < lhs.count {
            for column in columns {
                let offset = rowStart + column * 4
                guard offset + 3 < lhs.count else { continue }
                let same = lhs[offset] == rhs[offset]
                    && lhs[offset + 1] == rhs[offset + 1]
                    && lhs[offset + 2] == rhs[offset + 2]
                    && lhs[offset + 3] == rhs[offset + 3]
                if !same { count += 1 }
            }
            rowStart += bytesPerRow
        }
        return count
    }

    // MARK: - Invisible characters

    @Test("An empty trigger set never reads the document")
    func emptyTriggerSetNeverReadsTheDocument() throws {
        let text = String(repeating: "SELECT name FROM users ", count: 4_000)
        let storage = CountingTextStorage()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        storage.setAttributes([.font: font], range: NSRange(location: 0, length: (text as NSString).length))
        let delegate = RecordingInvisibleDelegate(triggerCharacters: [])
        let renderer = LineFragmentRenderer(textStorage: storage, invisibleCharacterDelegate: delegate)
        let fragment = try makeFragment(text)
        let context = try #require(makeContext(window: CGRect(x: 0, y: 0, width: 400, height: 34)))

        storage.resetCount()
        renderer.draw(lineFragment: fragment, in: context, yPos: 0)

        #expect(storage.stringAccessCount == 0)
        #expect(delegate.requestedIndices.isEmpty)
    }

    @Test("Invisible characters are scanned only where the clip reaches")
    func invisiblesAreScannedOnlyWhereTheClipReaches() throws {
        let text = String(repeating: "abcdefghi ", count: 10_000)
        let storage = makeStorage(text)
        let delegate = RecordingInvisibleDelegate(triggerCharacters: [space])
        let renderer = LineFragmentRenderer(textStorage: storage, invisibleCharacterDelegate: delegate)
        let fragment = try makeFragment(text)

        let window = CGRect(x: fragment.width / 2, y: 0, width: 400, height: 34)
        let context = try #require(makeContext(window: window))
        renderer.draw(lineFragment: fragment, in: context, yPos: 0)

        #expect(!delegate.requestedIndices.isEmpty)
        #expect(delegate.requestedIndices.count < 100, "scanned \(delegate.requestedIndices.count) characters")
        let lowest = Int(window.minX / characterWidth) - 50
        let highest = Int(window.maxX / characterWidth) + 50
        for index in delegate.requestedIndices {
            #expect(index >= lowest && index <= highest, "index \(index) outside \(lowest)...\(highest)")
        }
    }

    @Test("A content ends its own scan at its own end")
    func contentEndsItsOwnScan() throws {
        let text = "aa aa \u{FFFC} bb bb"
        let storage = makeStorage(text)
        let delegate = RecordingInvisibleDelegate(triggerCharacters: [space])
        let renderer = LineFragmentRenderer(textStorage: storage, invisibleCharacterDelegate: delegate)
        let attachment = AnyTextAttachment(
            range: NSRange(location: 6, length: 1),
            attachment: DemoTextAttachment(width: 30)
        )
        let fragment = try makeFragment(text, attachments: [attachment])
        #expect(fragment.contents.count == 3)

        let context = try #require(makeContext(window: CGRect(x: 0, y: 0, width: fragment.width, height: 34)))
        renderer.draw(lineFragment: fragment, in: context, yPos: 0)

        let spaces = (text as NSString).length - text.replacingOccurrences(of: " ", with: "").utf16.count
        #expect(delegate.requestedIndices.count == spaces)
        #expect(Set(delegate.requestedIndices).count == delegate.requestedIndices.count)
    }

    @Test("The scan range covers the whole content when nothing bounds it")
    func scanRangeCoversTheWholeContentWhenUnbounded() {
        let contentRange = CFRange(location: 40, length: 25)
        let unbounded = LineFragmentRenderer.contentScanRange(contentRange: contentRange, visibleRange: nil)
        #expect(unbounded == NSRange(location: 0, length: 25))
    }

    @Test("The scan range is clamped into the content it belongs to")
    func scanRangeIsClampedIntoItsContent() {
        let contentRange = CFRange(location: 40, length: 25)
        let inside = LineFragmentRenderer.contentScanRange(
            contentRange: contentRange,
            visibleRange: CFRange(location: 45, length: 10)
        )
        #expect(inside == NSRange(location: 5, length: 10))

        let before = LineFragmentRenderer.contentScanRange(
            contentRange: contentRange,
            visibleRange: CFRange(location: 0, length: 10)
        )
        #expect(before == NSRange(location: 0, length: 0))

        let after = LineFragmentRenderer.contentScanRange(
            contentRange: contentRange,
            visibleRange: CFRange(location: 60, length: 40)
        )
        #expect(after == NSRange(location: 20, length: 5))
    }

    // MARK: - Drawing

    @Test("A clipped render matches an unclipped one inside the clip", arguments: [0, 1, 2])
    func clippedRenderMatchesUnclippedRender(stripIndex: Int) throws {
        let text = String(repeating: "SELECT id, name FROM users ", count: 8)
            + "\u{FFFC}"
            + String(repeating: "WHERE name LIKE 'abc%' AND id = 42 ", count: 8)
        let storage = makeStorage(text)
        let attachmentLocation = (String(repeating: "SELECT id, name FROM users ", count: 8) as NSString).length
        let attachment = AnyTextAttachment(
            range: NSRange(location: attachmentLocation, length: 1),
            attachment: DemoTextAttachment(width: 30)
        )
        let renderer = LineFragmentRenderer(textStorage: storage, invisibleCharacterDelegate: nil)
        let fragment = try makeFragment(text, attachments: [attachment])
        #expect(fragment.contents.count == 3)

        let attachmentX = fragment.xPosition(for: attachmentLocation)
        let strips = [
            CGRect(x: (attachmentX / 2).rounded(), y: 0, width: 60, height: 34),
            CGRect(x: (attachmentX - 20).rounded(), y: 0, width: 60, height: 34),
            CGRect(x: (attachmentX + (fragment.width - attachmentX) / 2).rounded(), y: 0, width: 60, height: 34)
        ]
        let strip = strips[stripIndex]
        let bounds = CGRect(x: 0, y: 0, width: fragment.width.rounded(.up), height: 34)

        let wholeContext = try #require(makeContext(window: bounds))
        renderer.draw(lineFragment: fragment, in: wholeContext, yPos: 0)
        let whole = bytes(of: wholeContext)

        let clippedContext = try #require(makeContext(window: bounds))
        clippedContext.clip(to: strip)
        renderer.draw(lineFragment: fragment, in: clippedContext, yPos: 0)
        let clipped = bytes(of: clippedContext)

        let columns = Int(strip.minX)..<Int(strip.maxX)
        let mismatching = columns.filter { column in
            mismatchingPixels(
                whole,
                clipped,
                bytesPerRow: wholeContext.bytesPerRow,
                columns: column..<(column + 1)
            ) > 0
        }
        #expect(mismatching.isEmpty, "strip at \(strip.minX) differs in columns \(mismatching)")
    }

    @Test("Drawing a long line into a narrow clip costs less than drawing all of it")
    func narrowClipCostsLessThanTheWholeLine() throws {
        let text = String(repeating: "SELECT id, name FROM users WHERE id = 42 ", count: 5_000)
        let storage = makeStorage(text)
        let renderer = LineFragmentRenderer(textStorage: storage, invisibleCharacterDelegate: nil)
        let fragment = try makeFragment(text)
        let ctLine = try #require(textLine(of: fragment))
        let window = CGRect(x: fragment.width / 2, y: 0, width: 60, height: 34)

        let clipped = bestSeconds(window: window) { context in
            renderer.draw(lineFragment: fragment, in: context, yPos: 0)
        }
        let whole = bestSeconds(window: window) { context in
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
        }

        #expect(clipped * 4 < whole, "clipped \(clipped)s against \(whole)s for the whole line")
    }
}
