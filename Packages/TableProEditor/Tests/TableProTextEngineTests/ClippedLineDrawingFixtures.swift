import AppKit
import CoreText
@testable import TableProTextEngine

/// Names a line the plan has to judge, so a parameterised failure prints something readable.
struct ClippedLineDrawingCase: CustomStringConvertible, Sendable {
    let name: String
    let drawsGlyphRanges: Bool

    var description: String { name }

    static let all: [ClippedLineDrawingCase] = [
        ClippedLineDrawingCase(name: "plain", drawsGlyphRanges: true),
        ClippedLineDrawingCase(name: "twoColors", drawsGlyphRanges: true),
        ClippedLineDrawingCase(name: "superscript", drawsGlyphRanges: true),
        ClippedLineDrawingCase(name: "underlineOff", drawsGlyphRanges: true),
        ClippedLineDrawingCase(name: "background", drawsGlyphRanges: true),
        ClippedLineDrawingCase(name: "baselineOffset", drawsGlyphRanges: false),
        ClippedLineDrawingCase(name: "underline", drawsGlyphRanges: false),
        ClippedLineDrawingCase(name: "strikethrough", drawsGlyphRanges: false),
        ClippedLineDrawingCase(name: "obliqueMatrix", drawsGlyphRanges: false)
    ]
}

/// A line of one script, so a raster failure names the script it came from.
///
/// ``drawsGlyphRanges`` is what the plan says about this script under ``ClippedLineDrawingFixtures/font``, and it is
/// the difference between a comparison that measures `CTRunDraw` against `CTLineDraw` and one that measures a full
/// draw against a full draw. A refused script still belongs here, because the fallback has to render identically
/// too, but only a line the plan accepts guards the drawing this design introduced.
///
/// A refusal is the script's own shaping and not the way the line is built: a mark positioned back over its cluster
/// breaks the exact advance sequencing the plan asks for, and the verdict is the same whether the line is a single
/// attribute run, split at token boundaries, or split every three or seven UTF-16 units. It does move with the face
/// that shapes the script, so it is stated per line rather than assumed.
struct CorpusLine: CustomStringConvertible, Sendable {
    let name: String
    let text: String
    let drawsGlyphRanges: Bool

    var description: String { name }

    static let all: [CorpusLine] = [
        CorpusLine(
            name: "plainSQL",
            text: repeated("SELECT id FROM users WHERE id = 42 "),
            drawsGlyphRanges: true
        ),
        CorpusLine(name: "cjk", text: repeated("日本語テキスト한국어中文字符 "), drawsGlyphRanges: true),
        CorpusLine(
            name: "emoji",
            text: repeated("a 👨‍👩‍👧‍👦🇻🇳👍🏽❤️ b 🧑🏿‍🚀 c ", times: 4),
            drawsGlyphRanges: true
        ),
        CorpusLine(name: "arabicPlain", text: repeated("x مرحبا بالعالم y ", times: 4), drawsGlyphRanges: true),
        CorpusLine(
            name: "arabicHarakat",
            text: repeated("x مَرْحَبًا بِالْعَالَمِ y ", times: 4),
            drawsGlyphRanges: false
        ),
        CorpusLine(name: "hebrewPlain", text: repeated("x שלום עולם y ", times: 4), drawsGlyphRanges: true),
        CorpusLine(
            name: "hebrewNiqqud",
            text: repeated("x שָׁלוֹם עוֹלָם y ", times: 4),
            drawsGlyphRanges: false
        ),
        CorpusLine(name: "devanagari", text: repeated("x नमस्ते दुनिया y ", times: 4), drawsGlyphRanges: false),
        CorpusLine(name: "thai", text: repeated("x สวัสดีครับ y ", times: 4), drawsGlyphRanges: true),
        CorpusLine(name: "khmer", text: repeated("x សួស្តី ពិភពលោក y ", times: 4), drawsGlyphRanges: false),
        CorpusLine(name: "myanmar", text: repeated("x မင်္ဂလာပါ ကမ္ဘာ y ", times: 4), drawsGlyphRanges: false),
        CorpusLine(name: "tamil", text: repeated("x வணக்கம் உலகம் y ", times: 4), drawsGlyphRanges: false),
        CorpusLine(
            name: "hangulJamo",
            text: repeated("x \u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF} y "),
            drawsGlyphRanges: true
        ),
        CorpusLine(
            name: "mathBidi",
            text: repeated("x = مرحبا + 42 * שלום / y ", times: 4),
            drawsGlyphRanges: true
        ),
        CorpusLine(
            name: "combiningLatin",
            text: repeated("e\u{301}e\u{302}\u{323}a\u{30A} Z\u{36B}\u{35C} "),
            drawsGlyphRanges: false
        ),
        CorpusLine(
            name: "vietnameseNFD",
            text: repeated("Tiếng Việt xin chào ").decomposedStringWithCanonicalMapping,
            drawsGlyphRanges: true
        ),
        CorpusLine(name: "tabs", text: repeated("col\tvalue\tnext\tlast "), drawsGlyphRanges: true)
    ]

    private static func repeated(_ text: String, times: Int = 5) -> String {
        String(repeating: text, count: times)
    }
}

/// Lines, drawing contexts and pixel comparisons shared by the clipped drawing suites.
struct ClippedLineDrawingFixtures {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let colorA = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.5, alpha: 1)
    let colorB = NSColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1)

    enum RenderMode {
        case full
        case clipped
        case insideWindowOnly
    }

    // MARK: - Line building

    func makeLine(_ string: NSAttributedString) -> CTLine {
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        return CTTypesetterCreateLine(typesetter, CFRangeMake(0, string.length))
    }

    func line(_ pieces: [(String, [NSAttributedString.Key: Any])]) -> CTLine {
        let string = NSMutableAttributedString()
        for (text, attributes) in pieces {
            var merged = attributes
            if merged[.font] == nil { merged[.font] = font }
            if merged[.foregroundColor] == nil { merged[.foregroundColor] = colorA }
            string.append(NSAttributedString(string: text, attributes: merged))
        }
        return makeLine(string)
    }

    /// Splits text into seven character runs of alternating colour, which is the shape syntax highlighting gives a
    /// line and the reason a long line can hold tens of thousands of runs.
    ///
    /// Cutting a combining sequence in half is deliberate, because a highlighter can, and measured it changes no
    /// plan's verdict. Cutting a surrogate pair in half is not: the halves shape as LastResort's replacement glyph,
    /// which took 14 of the emoji line's glyphs off the emoji font the line exists to cover.
    func coloured(_ text: String) -> CTLine {
        let attributed = NSMutableAttributedString()
        let nsText = text as NSString
        var index = 0
        var isFirstColor = true
        while index < nsText.length {
            let length = colorRunLength(in: nsText, from: index)
            attributed.append(NSAttributedString(
                string: nsText.substring(with: NSRange(location: index, length: length)),
                attributes: [.font: font, .foregroundColor: isFirstColor ? colorA : colorB]
            ))
            isFirstColor.toggle()
            index += length
        }
        return makeLine(attributed)
    }

    private func colorRunLength(in text: NSString, from index: Int) -> Int {
        let length = min(7, text.length - index)
        let end = index + length
        guard end < text.length else { return length }
        let last = text.character(at: end - 1)
        guard last >= 0xD800, last <= 0xDBFF else { return length }
        return length + 1
    }

    func namedLine(_ name: String) -> CTLine {
        var skew = CGAffineTransform(a: 1, b: 0, c: 0.3, d: 1, tx: 0, ty: 0)
        let oblique = CTFontCreateWithName("Menlo-Regular" as CFString, 13, &skew)
        switch name {
        case "twoColors":
            return line([("SELECT ", [:]), ("id, name ", [.foregroundColor: colorB]), ("FROM users", [:])])
        case "superscript":
            return line([("plain ", [:]), ("x2", [.superscript: 1]), (" plain", [:])])
        case "underlineOff":
            return line([("plain ", [:]), ("not marked", [.underlineStyle: 0]), (" plain", [:])])
        case "background":
            return line([("plain ", [:]), ("highlighted", [.backgroundColor: NSColor.yellow]), (" plain", [:])])
        case "baselineOffset":
            return line([("plain ", [:]), ("raised", [.baselineOffset: 4.0]), (" plain", [:])])
        case "underline":
            return line([
                ("plain ", [:]),
                ("marked text", [.underlineStyle: NSUnderlineStyle.single.rawValue]),
                (" plain", [:])
            ])
        case "strikethrough":
            return line([("plain ", [:]), ("struck", [.strikethroughStyle: 1]), (" plain", [:])])
        case "obliqueMatrix":
            return line([("plain ", [:]), ("slanted", [.font: oblique]), (" plain", [:])])
        default:
            return line([("SELECT id, name FROM users WHERE id = 42 AND name LIKE 'abc%';", [:])])
        }
    }

    /// A line carrying every feature the design has to keep identical: several colours, CJK, emoji, tabs, a real
    /// italic face, a decorative face, decomposed Latin, kerning and a background colour.
    func mixedLine() -> CTLine {
        let times = NSFont(name: "Times New Roman", size: 13) ?? font
        let zapfino = NSFont(name: "Zapfino", size: 13) ?? font
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        var pieces: [(String, [NSAttributedString.Key: Any])] = []
        for index in 0..<40 {
            pieces.append(("SELECT id, name FROM users WHERE ", [.foregroundColor: colorB]))
            pieces.append(("'日本語テキスト한국어' ", [:]))
            pieces.append(("👨‍👩‍👧‍👦🇻🇳👍🏽 ", [:]))
            pieces.append(("col\tvalue\t", [:]))
            pieces.append(("italicWfj ", [.font: italic]))
            pieces.append(("fi fl ffi AV To Wa ", [.font: times]))
            pieces.append(("fZapfino ", [.font: zapfino]))
            pieces.append((
                "Tiếng Việt xin chào ".decomposedStringWithCanonicalMapping,
                [.foregroundColor: index % 2 == 0 ? colorA : colorB]
            ))
            pieces.append(("kerned ", [.kern: 1.5]))
            pieces.append(("highlighted ", [.backgroundColor: NSColor.yellow]))
        }
        return line(pieces)
    }

    // MARK: - Core Text access

    func runs(of ctLine: CTLine) -> [CTRun] {
        let array = CTLineGetGlyphRuns(ctLine)
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let raw = CFArrayGetValueAtIndex(array, index) else { return nil }
            return Unmanaged<CTRun>.fromOpaque(raw).takeUnretainedValue()
        }
    }

    func positions(of run: CTRun) -> [CGPoint] {
        var storage = [CGPoint](repeating: .zero, count: CTRunGetGlyphCount(run))
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &storage)
        return storage
    }

    func advances(of run: CTRun) -> [CGSize] {
        var storage = [CGSize](repeating: .zero, count: CTRunGetGlyphCount(run))
        CTRunGetAdvances(run, CFRange(location: 0, length: 0), &storage)
        return storage
    }

    func stringIndices(of run: CTRun) -> [CFIndex] {
        var storage = [CFIndex](repeating: 0, count: CTRunGetGlyphCount(run))
        CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &storage)
        return storage
    }

    func width(of ctLine: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
    }

    /// The PostScript name of the face shaping each run, which is how a line says which fallback it really landed on.
    func runFontNames(of ctLine: CTLine) -> [String] {
        runs(of: ctLine).compactMap { run in
            let attributes = CTRunGetAttributes(run)
            let key = Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()
            guard let raw = CFDictionaryGetValue(attributes, key) else { return nil }
            let value = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
            guard CFGetTypeID(value) == CTFontGetTypeID() else { return nil }
            let runFont = Unmanaged<CTFont>.fromOpaque(raw).takeUnretainedValue()
            return CTFontCopyPostScriptName(runFont) as String
        }
    }

    // MARK: - Rendering

    func makeContext(window: CGRect, scale: CGFloat = 1, opaque: Bool = false) -> CGContext? {
        let pixelWidth = Int(ceil(window.width * scale))
        let pixelHeight = Int(ceil(window.height * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
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
        if opaque {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -window.minX, y: -window.minY)
        context.clip(to: window)
        return context
    }

    /// Applies the state ``LineFragmentRenderer`` draws with, so a comparison measures the drawing and not the setup.
    func applyRendererState(_ context: CGContext) {
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelQuantization(true)
        context.setShouldSubpixelQuantizeFonts(true)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    }

    func render(
        _ ctLine: CTLine,
        window: CGRect,
        scale: CGFloat = 1,
        opaque: Bool = false,
        originX: CGFloat = 0,
        mode: RenderMode
    ) -> [UInt8] {
        guard let context = makeContext(window: window, scale: scale, opaque: opaque) else { return [] }
        context.saveGState()
        applyRendererState(context)
        let origin = CGPoint(x: originX, y: 17).pixelAligned
        switch mode {
        case .full:
            context.textPosition = origin
            CTLineDraw(ctLine, context)
        case .clipped:
            ClippedLineDrawing.draw(
                ctLine,
                plan: ClippedLineDrawing.Plan(ctLine: ctLine),
                at: origin,
                width: width(of: ctLine),
                in: context
            )
        case .insideWindowOnly:
            drawGlyphsStrictlyInside(ctLine, window: window, origin: origin, in: context)
        }
        context.restoreGState()
        guard let data = context.data else { return [] }
        let length = context.bytesPerRow * context.height
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: length))
    }

    /// The mistake the design guards against: drawing only the glyphs whose own position sits inside the window,
    /// with no ink reach and no glyph taken from before the left edge.
    private func drawGlyphsStrictlyInside(
        _ ctLine: CTLine,
        window: CGRect,
        origin: CGPoint,
        in context: CGContext
    ) {
        let minX = window.minX - origin.x
        let maxX = window.maxX - origin.x
        for run in runs(of: ctLine) {
            let runPositions = positions(of: run)
            guard let start = runPositions.firstIndex(where: { $0.x >= minX }),
                  let last = runPositions.lastIndex(where: { $0.x < maxX }),
                  last >= start else {
                continue
            }
            context.textPosition = origin
            CTRunDraw(run, context, CFRange(location: start, length: last - start + 1))
        }
    }

    func mismatchingPixels(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .max }
        var count = 0
        var index = 0
        while index < lhs.count {
            if lhs[index] != rhs[index] || lhs[index + 1] != rhs[index + 1]
                || lhs[index + 2] != rhs[index + 2] || lhs[index + 3] != rhs[index + 3] {
                count += 1
            }
            index += 4
        }
        return count
    }

    func windows(across lineWidth: CGFloat, count: Int, width: CGFloat = 60) -> [CGRect] {
        guard count > 1 else { return [CGRect(x: 0, y: 0, width: width, height: 34)] }
        let step = max(1, (lineWidth - width) / CGFloat(count - 1))
        return (0..<count).map { index in
            CGRect(x: (CGFloat(index) * step).rounded(), y: 0, width: width, height: 34)
        }
    }
}
