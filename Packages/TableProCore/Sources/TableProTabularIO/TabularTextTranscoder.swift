import Foundation

public struct TabularTranscodedText: Sendable {
    public let map: TabularTranscodingMap
    public let undecodableLineCount: Int
    public let firstUndecodableLine: Int?
}

public struct TabularTranscodedData: Sendable {
    public let data: Data
    public let undecodableLineCount: Int
    public let firstUndecodableLine: Int?
}

public enum TabularTextTranscoder {
    public static let chunkLength = 1 << 20

    private static let replacementCharacter: [UInt8] = Array("\u{FFFD}".utf8)
    private static let longestCharacterLength = 4

    public static func transcode(
        _ data: Data,
        from encoding: TabularTextEncoding,
        skippingPrefix prefixLength: Int,
        to url: URL,
        progress: (Double) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> TabularTranscodedText {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw TabularWriteError.couldNotCreate(path: url.path)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw TabularWriteError.writeFailed(message: error.localizedDescription)
        }
        defer { try? handle.close() }
        let outcome = try run(data, from: encoding, skippingPrefix: prefixLength, progress: progress, isCancelled: isCancelled) {
            do {
                try handle.write(contentsOf: $0)
            } catch {
                throw TabularWriteError.writeFailed(message: error.localizedDescription)
            }
        }
        let map = TabularTranscodingMap(
            original: data,
            encoding: encoding,
            transcodedStarts: outcome.transcodedStarts,
            originalStarts: outcome.originalStarts
        )
        return TabularTranscodedText(
            map: map,
            undecodableLineCount: outcome.undecodableLineCount,
            firstUndecodableLine: outcome.firstUndecodableLine
        )
    }

    public static func utf8Data(
        from data: Data,
        encoding: TabularTextEncoding,
        skippingPrefix prefixLength: Int,
        wholeLinesWithin length: Int = .max
    ) throws -> TabularTranscodedData {
        let end = wholeLinesEnd(of: data, encoding: encoding, from: prefixLength, within: length)
        var output = Data()
        let outcome = try run(data.prefix(end), from: encoding, skippingPrefix: prefixLength, progress: { _ in }, isCancelled: { false }) {
            output.append(contentsOf: $0)
        }
        return TabularTranscodedData(
            data: output,
            undecodableLineCount: outcome.undecodableLineCount,
            firstUndecodableLine: outcome.firstUndecodableLine
        )
    }

    private static func wholeLinesEnd(of data: Data, encoding: TabularTextEncoding, from start: Int, within length: Int) -> Int {
        let start = min(start, data.count)
        guard length < data.count - start else { return data.count }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return encoding.codeUnitLayout.endOfLastLineBreak(in: bytes, from: start, before: start + length) ?? start + length
        }
    }

    public static func firstInvalidUTF8Line(in data: Data, skippingPrefix prefixLength: Int) -> Int? {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let layout = TabularCodeUnitLayout.asciiCompatible
            var lineStart = min(prefixLength, bytes.count)
            var lineNumber = 1
            while lineStart < bytes.count {
                let lineEnd = layout.endOfNextLineBreak(in: bytes, from: lineStart, notBefore: lineStart) ?? bytes.count
                let line = UnsafeBufferPointer(rebasing: bytes[lineStart..<lineEnd])
                if line.contains(where: { $0 >= 0x80 }), !isValidUTF8(line) {
                    return lineNumber
                }
                lineNumber += 1
                lineStart = lineEnd
            }
            return nil
        }
    }

    private static func isValidUTF8(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var iterator = bytes.makeIterator()
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

    private struct Outcome {
        var transcodedStarts: [Int] = []
        var originalStarts: [Int] = []
        var undecodableLineCount = 0
        var firstUndecodableLine: Int?
    }

    private struct DecodedChunk {
        var utf8: [UInt8] = []
        var undecodableLineCount = 0
        var firstUndecodableLineIndex: Int?
        var startsUndecodable = false
        var endsUndecodable = false
    }

    private static func run(
        _ data: Data,
        from encoding: TabularTextEncoding,
        skippingPrefix prefixLength: Int,
        progress: (Double) -> Void,
        isCancelled: () -> Bool,
        emit: ([UInt8]) throws -> Void
    ) throws -> Outcome {
        let layout = encoding.codeUnitLayout
        var outcome = Outcome()
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = min(prefixLength, bytes.count)
            var transcodedOffset = 0
            var linesBefore = 0
            var openLineIsCounted = false
            outcome.transcodedStarts.append(0)
            outcome.originalStarts.append(start)
            while start < bytes.count {
                if isCancelled() { throw TabularCancellation() }
                let end = chunkEnd(in: bytes, from: start, layout: layout)
                if start > outcome.originalStarts[outcome.originalStarts.count - 1] {
                    outcome.transcodedStarts.append(transcodedOffset)
                    outcome.originalStarts.append(start)
                }
                let chunk = UnsafeBufferPointer(rebasing: bytes[start..<end])
                let decoded = decode(chunk, encoding: encoding)
                try emit(decoded.utf8)
                transcodedOffset += decoded.utf8.count
                let recountsOpenLine = openLineIsCounted && decoded.startsUndecodable
                outcome.undecodableLineCount += decoded.undecodableLineCount - (recountsOpenLine ? 1 : 0)
                if outcome.firstUndecodableLine == nil, let index = decoded.firstUndecodableLineIndex {
                    outcome.firstUndecodableLine = linesBefore + index + 1
                }
                let lines = layout.lineCount(in: chunk, from: 0, to: chunk.count)
                let endsMidLine = chunk.count < layout.width
                    || layout.lineBreakByte(in: chunk, at: chunk.count - layout.width) == nil
                let openLineWasCounted = lines == 0 ? openLineIsCounted || decoded.startsUndecodable : decoded.endsUndecodable
                openLineIsCounted = endsMidLine && openLineWasCounted
                linesBefore += lines
                progress(Double(end) / Double(bytes.count))
                start = end
            }
        }
        return outcome
    }

    private static func chunkEnd(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, layout: TabularCodeUnitLayout) -> Int {
        let target = start + chunkLength
        guard target < bytes.count else { return bytes.count }
        return layout.endOfLastLineBreak(in: bytes, from: start, before: target)
            ?? layout.endOfLastCharacter(in: bytes, from: start, before: target)
            ?? layout.endOfNextCharacter(in: bytes, from: start, notBefore: target)
            ?? bytes.count
    }

    private static func decode(_ chunk: UnsafeBufferPointer<UInt8>, encoding: TabularTextEncoding) -> DecodedChunk {
        switch encoding {
        case .utf8:
            return DecodedChunk(utf8: Array(chunk))
        case .windows1252, .isoLatin1:
            var utf8: [UInt8] = []
            utf8.reserveCapacity(chunk.count + chunk.count / 4)
            TabularTextCodec.appendUTF8(of: chunk, from: encoding, into: &utf8)
            return DecodedChunk(utf8: utf8)
        case .utf16LittleEndian, .utf16BigEndian, .shiftJIS, .eucJP, .gb18030, .big5, .eucKR:
            let layout = encoding.codeUnitLayout
            if let strict = strictUTF8(chunk, encoding: encoding),
               layout.lineBreakCount(in: chunk, from: 0, to: chunk.count)
               == strict.withUnsafeBufferPointer({ TabularCodeUnitLayout.asciiCompatible.lineBreakCount(in: $0, from: 0, to: $0.count) }) {
                return DecodedChunk(utf8: strict)
            }
            return decodeLineByLine(chunk, encoding: encoding)
        }
    }

    private static func strictUTF8(_ bytes: UnsafeBufferPointer<UInt8>, encoding: TabularTextEncoding) -> [UInt8]? {
        guard bytes.count.isMultiple(of: encoding.codeUnitLayout.width) else { return nil }
        guard !bytes.isEmpty else { return [] }
        guard isWellFormed(bytes, as: encoding),
              let text = String(bytes: bytes, encoding: encoding.foundationEncoding) else { return nil }
        return Array(text.utf8)
    }

    private static func isWellFormed(_ bytes: UnsafeBufferPointer<UInt8>, as encoding: TabularTextEncoding) -> Bool {
        guard encoding == .eucJP else { return true }
        var offset = 0
        while offset < bytes.count {
            guard let length = eucJPCharacterLength(in: bytes, at: offset) else { return false }
            offset += length
        }
        return true
    }

    private static func eucJPCharacterLength(in bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Int? {
        switch bytes[offset] {
        case 0x00...0x7F:
            return 1
        case 0x8E:
            return hasTrail(bytes, after: offset, count: 1, in: 0xA1...0xDF) ? 2 : nil
        case 0x8F:
            return hasTrail(bytes, after: offset, count: 2, in: 0xA1...0xFE) ? 3 : nil
        case 0xA1...0xFE:
            return hasTrail(bytes, after: offset, count: 1, in: 0xA1...0xFE) ? 2 : nil
        default:
            return nil
        }
    }

    private static func hasTrail(
        _ bytes: UnsafeBufferPointer<UInt8>,
        after offset: Int,
        count: Int,
        in range: ClosedRange<UInt8>
    ) -> Bool {
        guard offset + count < bytes.count else { return false }
        return (1...count).allSatisfy { range.contains(bytes[offset + $0]) }
    }

    private static func decodeLineByLine(_ chunk: UnsafeBufferPointer<UInt8>, encoding: TabularTextEncoding) -> DecodedChunk {
        let layout = encoding.codeUnitLayout
        var decoded = DecodedChunk()
        decoded.utf8.reserveCapacity(chunk.count * 2)
        var lineStart = 0
        var offset = 0
        while offset + layout.width <= chunk.count {
            guard let lineBreak = layout.lineBreakByte(in: chunk, at: offset) else {
                offset += layout.width
                continue
            }
            appendLine(in: chunk, lineStart..<offset, encoding: encoding, into: &decoded)
            decoded.utf8.append(lineBreak)
            offset += layout.width
            lineStart = offset
        }
        if lineStart < chunk.count {
            appendLine(in: chunk, lineStart..<chunk.count, encoding: encoding, into: &decoded)
        }
        return decoded
    }

    private static func appendLine(
        in chunk: UnsafeBufferPointer<UInt8>,
        _ range: Range<Int>,
        encoding: TabularTextEncoding,
        into decoded: inout DecodedChunk
    ) {
        let line = UnsafeBufferPointer(rebasing: chunk[range])
        if let strict = strictUTF8(line, encoding: encoding) {
            decoded.utf8.append(contentsOf: strict)
            return
        }
        decoded.undecodableLineCount += 1
        decoded.startsUndecodable = decoded.startsUndecodable || range.lowerBound == 0
        decoded.endsUndecodable = range.upperBound == chunk.count
        if decoded.firstUndecodableLineIndex == nil {
            decoded.firstUndecodableLineIndex = encoding.codeUnitLayout.lineCount(in: chunk, from: 0, to: range.lowerBound)
        }
        switch encoding.codeUnitLayout {
        case .utf16LittleEndian, .utf16BigEndian:
            appendLossyUTF16(line, layout: encoding.codeUnitLayout, into: &decoded.utf8)
        case .asciiCompatible:
            appendLossyMultiByte(line, encoding: encoding, into: &decoded.utf8)
        }
    }

    private static func appendLossyUTF16(_ line: UnsafeBufferPointer<UInt8>, layout: TabularCodeUnitLayout, into utf8: inout [UInt8]) {
        let unitCount = line.count / 2
        var units: [UInt16] = []
        units.reserveCapacity(unitCount)
        for index in 0..<unitCount {
            let first = UInt16(line[index * 2])
            let second = UInt16(line[index * 2 + 1])
            units.append(layout == .utf16LittleEndian ? first | second << 8 : first << 8 | second)
        }
        utf8.append(contentsOf: String(decoding: units, as: UTF16.self).utf8)
        if !line.count.isMultiple(of: 2) {
            utf8.append(contentsOf: replacementCharacter)
        }
    }

    private static func appendLossyMultiByte(_ line: UnsafeBufferPointer<UInt8>, encoding: TabularTextEncoding, into utf8: inout [UInt8]) {
        var offset = 0
        while offset < line.count {
            let byte = line[offset]
            if byte < 0x80 {
                utf8.append(byte)
                offset += 1
                continue
            }
            guard let character = firstCharacter(in: line, at: offset, encoding: encoding) else {
                utf8.append(contentsOf: replacementCharacter)
                offset += 1
                continue
            }
            utf8.append(contentsOf: character.text.utf8)
            offset += character.length
        }
    }

    private static func firstCharacter(
        in line: UnsafeBufferPointer<UInt8>,
        at offset: Int,
        encoding: TabularTextEncoding
    ) -> (text: String, length: Int)? {
        let longest = min(longestCharacterLength, line.count - offset)
        for length in 1...longest {
            let candidate = UnsafeBufferPointer(rebasing: line[offset..<offset + length])
            if isWellFormed(candidate, as: encoding),
               let text = String(bytes: candidate, encoding: encoding.foundationEncoding), text.unicodeScalars.count == 1 {
                return (text, length)
            }
        }
        return nil
    }
}
