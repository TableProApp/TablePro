import Foundation

public struct TabularEncodingSniff: Equatable, Sendable {
    public let encoding: TabularTextEncoding
    public let byteOrderMarkLength: Int

    public init(encoding: TabularTextEncoding, byteOrderMarkLength: Int) {
        self.encoding = encoding
        self.byteOrderMarkLength = byteOrderMarkLength
    }

    public var hasByteOrderMark: Bool { byteOrderMarkLength > 0 }
}

public enum TabularEncodingDetector {
    public static let sampleLength = 65_536

    static let legacyCandidates: [TabularTextEncoding] = [.shiftJIS, .eucJP, .gb18030, .big5, .eucKR, .windows1252]

    private static let markedEncodings: [TabularTextEncoding] = [.utf8, .utf16LittleEndian, .utf16BigEndian]
    private static let asciiScanLimit = 64 << 20
    private static let structuralScalars: Set<UInt32> = [0x09, 0x0A, 0x0D, 0x22, 0x2C, 0x3B, 0x7C]
    private static let halfWidthKatakana: ClosedRange<UInt8> = 0xA1...0xDF
    private static let halfWidthKatakanaShare = 0.9
    private static let halfWidthKatakanaRunLength = 3
    private static let halfWidthKatakanaRunShare = 0.5
    private static let undecodableLineShareLimit = 10
    private static let eastAsianScalars: [ClosedRange<UInt32>] = [
        0x1100...0x11FF, 0x2460...0x24FF, 0x3000...0x303F, 0x3040...0x30FF, 0x3100...0x312F, 0x3130...0x318F,
        0x3200...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFF01...0xFF60,
        0xFFE0...0xFFEF
    ]

    public static func sniff(_ data: Data, isWholeFile: Bool = true) -> TabularEncodingSniff {
        data.withUnsafeBytes { sniff($0.bindMemory(to: UInt8.self), isWholeFile: isWholeFile) }
    }

    public static func sniff(_ bytes: UnsafeBufferPointer<UInt8>, isWholeFile: Bool = true) -> TabularEncodingSniff {
        if let marked = byteOrderMarkSniff(bytes) {
            return marked
        }
        let head = UnsafeBufferPointer(rebasing: bytes[0..<min(bytes.count, sampleLength)])
        if let utf16 = unmarkedUTF16(head) {
            return TabularEncodingSniff(encoding: utf16, byteOrderMarkLength: 0)
        }
        guard let window = sampleWindow(in: bytes, isWholeFile: isWholeFile) else {
            return TabularEncodingSniff(encoding: .utf8, byteOrderMarkLength: 0)
        }
        return TabularEncodingSniff(encoding: encoding(of: window), byteOrderMarkLength: 0)
    }

    private static func byteOrderMarkSniff(_ bytes: UnsafeBufferPointer<UInt8>) -> TabularEncodingSniff? {
        for encoding in markedEncodings where hasPrefix(bytes, encoding.byteOrderMark) {
            return TabularEncodingSniff(encoding: encoding, byteOrderMarkLength: encoding.byteOrderMark.count)
        }
        return nil
    }

    private static func unmarkedUTF16(_ head: UnsafeBufferPointer<UInt8>) -> TabularTextEncoding? {
        let evenLength = head.count - head.count % 2
        guard evenLength >= 4 else { return nil }
        var nulBytes = 0
        var nulUnits = 0
        for unit in stride(from: 0, to: evenLength, by: 2) {
            let firstIsNul = head[unit] == 0
            let secondIsNul = head[unit + 1] == 0
            nulBytes += (firstIsNul ? 1 : 0) + (secondIsNul ? 1 : 0)
            nulUnits += firstIsNul && secondIsNul ? 1 : 0
        }
        guard nulBytes * 100 >= evenLength, nulUnits * 100 < evenLength / 2 else { return nil }
        let body = UnsafeBufferPointer(rebasing: head[0..<evenLength])
        let little = structuralScalarCount(body, as: .utf16LittleEndian) ?? 0
        let big = structuralScalarCount(body, as: .utf16BigEndian) ?? 0
        guard max(little, big) > 0, little != big else { return nil }
        return little > big ? .utf16LittleEndian : .utf16BigEndian
    }

    private static func structuralScalarCount(_ body: UnsafeBufferPointer<UInt8>, as encoding: TabularTextEncoding) -> Int? {
        let withoutSplitPair = UnsafeBufferPointer(rebasing: body[0..<max(0, body.count - 2)])
        guard let text = String(bytes: body, encoding: encoding.foundationEncoding)
            ?? String(bytes: withoutSplitPair, encoding: encoding.foundationEncoding) else {
            return nil
        }
        return text.unicodeScalars.reduce(into: 0) { count, scalar in
            if structuralScalars.contains(scalar.value) { count += 1 }
        }
    }

    private struct SampleWindow {
        let bytes: Data
        let mayEndInsideCharacter: Bool
    }

    private static func sampleWindow(in bytes: UnsafeBufferPointer<UInt8>, isWholeFile: Bool) -> SampleWindow? {
        guard let firstNonASCII = firstNonASCIIOffset(in: bytes) else { return nil }
        var start = firstNonASCII
        let lowestStart = max(0, firstNonASCII - sampleLength / 2)
        while start > lowestStart, !isLineBreak(bytes[start - 1]) {
            start -= 1
        }
        let end = min(bytes.count, start + sampleLength)
        guard end < bytes.count || !isWholeFile else {
            return SampleWindow(bytes: Data(UnsafeBufferPointer(rebasing: bytes[start..<end])), mayEndInsideCharacter: false)
        }
        guard let boundary = lastBoundary(in: bytes, from: firstNonASCII + 1, before: end) else {
            return SampleWindow(bytes: Data(UnsafeBufferPointer(rebasing: bytes[start..<end])), mayEndInsideCharacter: true)
        }
        return SampleWindow(bytes: Data(UnsafeBufferPointer(rebasing: bytes[start..<boundary])), mayEndInsideCharacter: false)
    }

    private static func lastBoundary(in bytes: UnsafeBufferPointer<UInt8>, from lowest: Int, before end: Int) -> Int? {
        var lastStandalone: Int?
        var offset = end - 1
        while offset >= lowest {
            let byte = bytes[offset]
            if isLineBreak(byte) { return offset + 1 }
            if lastStandalone == nil, byte < TabularCodeUnitLayout.lowestByteInsideACharacter { lastStandalone = offset + 1 }
            offset -= 1
        }
        return lastStandalone
    }

    private static func encoding(of window: SampleWindow) -> TabularTextEncoding {
        let isUTF8 = window.bytes.withUnsafeBytes {
            isValidUTF8($0.bindMemory(to: UInt8.self), allowingCutTail: window.mayEndInsideCharacter)
        }
        if isUTF8 || isMostlyUTF8(window.bytes) { return .utf8 }
        if let ranked = rankedLegacyEncoding(of: window.bytes), ranked != .windows1252,
           holdsEastAsianText(window.bytes, readAs: ranked) {
            return ranked
        }
        return looksLikeHalfWidthKatakana(window.bytes) ? .shiftJIS : .windows1252
    }

    private static func isMostlyUTF8(_ window: Data) -> Bool {
        var validLines = 0
        var invalidLines = 0
        for line in window.split(whereSeparator: isLineBreak) where line.contains(where: { $0 >= 0x80 }) {
            if String(data: Data(line), encoding: .utf8) == nil {
                invalidLines += 1
            } else {
                validLines += 1
            }
        }
        return validLines > invalidLines && invalidLines <= max(1, (validLines + invalidLines) / undecodableLineShareLimit)
    }

    private static func holdsEastAsianText(_ window: Data, readAs encoding: TabularTextEncoding) -> Bool {
        guard let text = mostlyDecodedText(window, as: encoding) else { return false }
        return text.unicodeScalars.contains { scalar in
            eastAsianScalars.contains { $0.contains(scalar.value) }
        }
    }

    private static func mostlyDecodedText(_ window: Data, as encoding: TabularTextEncoding) -> String? {
        guard let decoded = try? TabularTextTranscoder.utf8Data(from: window, encoding: encoding, skippingPrefix: 0) else {
            return nil
        }
        let lineCount = max(1, window.reduce(into: 0) { count, byte in
            if isLineBreak(byte) { count += 1 }
        })
        guard decoded.undecodableLineCount <= max(1, lineCount / undecodableLineShareLimit) else { return nil }
        return TabularTextCodec.utf8String(decoded.data)
    }

    private static func rankedLegacyEncoding(of window: Data) -> TabularTextEncoding? {
        let options: [StringEncodingDetectionOptionsKey: Any] = [
            .suggestedEncodingsKey: legacyCandidates.map { NSNumber(value: $0.foundationEncoding.rawValue) },
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: true
        ]
        let detected = NSString.stringEncoding(
            for: window,
            encodingOptions: options,
            convertedString: nil,
            usedLossyConversion: nil
        )
        return legacyCandidates.first { $0.foundationEncoding.rawValue == detected }
    }

    private static func looksLikeHalfWidthKatakana(_ window: Data) -> Bool {
        var nonASCII = 0
        var katakana = 0
        var runs = 0
        var longRuns = 0
        var run = 0
        for byte in window {
            if byte >= 0x80 {
                nonASCII += 1
                run += 1
                if halfWidthKatakana.contains(byte) { katakana += 1 }
                continue
            }
            if run > 0 {
                runs += 1
                if run >= halfWidthKatakanaRunLength { longRuns += 1 }
                run = 0
            }
        }
        if run > 0 {
            runs += 1
            if run >= halfWidthKatakanaRunLength { longRuns += 1 }
        }
        guard nonASCII > 0, runs > 0 else { return false }
        let katakanaShare = Double(katakana) / Double(nonASCII)
        let longRunShare = Double(longRuns) / Double(runs)
        return katakanaShare >= halfWidthKatakanaShare && longRunShare >= halfWidthKatakanaRunShare
            && mostlyDecodedText(window, as: .shiftJIS) != nil
    }

    private static func firstNonASCIIOffset(in bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        guard let base = bytes.baseAddress else { return nil }
        let highBits: UInt64 = 0x8080_8080_8080_8080
        let limit = min(bytes.count, asciiScanLimit)
        var offset = 0
        while offset + 8 <= limit {
            let word = UnsafeRawPointer(base + offset).loadUnaligned(as: UInt64.self)
            if word & highBits != 0 { break }
            offset += 8
        }
        while offset < limit {
            if bytes[offset] >= 0x80 { return offset }
            offset += 1
        }
        return nil
    }

    private static func isLineBreak(_ byte: UInt8) -> Bool {
        byte == 0x0A || byte == 0x0D
    }

    private static func hasPrefix(_ bytes: UnsafeBufferPointer<UInt8>, _ prefix: [UInt8]) -> Bool {
        guard !prefix.isEmpty, bytes.count >= prefix.count else { return false }
        for (offset, byte) in prefix.enumerated() where bytes[offset] != byte {
            return false
        }
        return true
    }

    private static func isValidUTF8(_ bytes: UnsafeBufferPointer<UInt8>, allowingCutTail: Bool) -> Bool {
        var end = bytes.count
        if allowingCutTail {
            var continuation = 0
            while end > 0, continuation < 3, (bytes[end - 1] & 0xC0) == 0x80 {
                end -= 1
                continuation += 1
            }
            if end > 0, bytes[end - 1] >= 0xC0 {
                end -= 1
            }
        }
        var iterator = UnsafeBufferPointer(rebasing: bytes[0..<end]).makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue:
                continue
            case .emptyInput:
                return true
            case .error:
                return false
            }
        }
    }
}
