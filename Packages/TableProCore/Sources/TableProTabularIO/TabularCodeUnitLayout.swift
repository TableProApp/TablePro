import Foundation

enum TabularCodeUnitLayout: Sendable {
    case asciiCompatible
    case utf16LittleEndian
    case utf16BigEndian

    var width: Int {
        switch self {
        case .asciiCompatible: return 1
        case .utf16LittleEndian, .utf16BigEndian: return 2
        }
    }

    func lineBreakByte(in bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt8? {
        switch self {
        case .asciiCompatible:
            return Self.lineBreak(bytes[offset])
        case .utf16LittleEndian:
            guard offset + 1 < bytes.count, bytes[offset + 1] == 0 else { return nil }
            return Self.lineBreak(bytes[offset])
        case .utf16BigEndian:
            guard offset + 1 < bytes.count, bytes[offset] == 0 else { return nil }
            return Self.lineBreak(bytes[offset + 1])
        }
    }

    func endOfLastLineBreak(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, before end: Int) -> Int? {
        guard end - start >= width else { return nil }
        var offset = aligned(end - width, from: start)
        while offset >= start {
            if let lineBreak = lineBreakByte(in: bytes, at: offset) {
                return endOfLineBreak(lineBreak, at: offset, in: bytes)
            }
            offset -= width
        }
        return nil
    }

    func endOfLastCharacter(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, before end: Int) -> Int? {
        guard end - start >= width else { return nil }
        var offset = aligned(end - width, from: start)
        while offset >= start {
            if endsCharacter(in: bytes, at: offset) { return offset + width }
            offset -= width
        }
        return nil
    }

    func endOfNextCharacter(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, notBefore floor: Int) -> Int? {
        var offset = max(start, aligned(floor, from: start))
        while offset + width <= bytes.count {
            if endsCharacter(in: bytes, at: offset) { return offset + width }
            offset += width
        }
        return nil
    }

    func lineCount(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Int {
        var count = 0
        var offset = start
        while offset + width <= end {
            if let lineBreak = lineBreakByte(in: bytes, at: offset),
               lineBreak == Self.lineFeed || !isLineFeed(in: bytes, at: offset + width, before: end) {
                count += 1
            }
            offset += width
        }
        return count
    }

    func endOfNextLineBreak(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, notBefore floor: Int) -> Int? {
        var offset = max(start, aligned(floor, from: start))
        while offset + width <= bytes.count {
            if let lineBreak = lineBreakByte(in: bytes, at: offset) {
                return endOfLineBreak(lineBreak, at: offset, in: bytes)
            }
            offset += width
        }
        return nil
    }

    func lineBreakCount(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Int {
        var count = 0
        var offset = start
        while offset + width <= end {
            if lineBreakByte(in: bytes, at: offset) != nil { count += 1 }
            offset += width
        }
        return count
    }

    func offset(afterLineBreaks count: Int, in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        guard count > 0 else { return start }
        var remaining = count
        var offset = start
        while offset + width <= bytes.count {
            if lineBreakByte(in: bytes, at: offset) != nil {
                remaining -= 1
                if remaining == 0 { return offset + width }
            }
            offset += width
        }
        return bytes.count
    }

    private func endOfLineBreak(_ lineBreak: UInt8, at offset: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Int {
        guard lineBreak == Self.carriageReturn, isLineFeed(in: bytes, at: offset + width, before: bytes.count) else {
            return offset + width
        }
        return offset + 2 * width
    }

    private func isLineFeed(in bytes: UnsafeBufferPointer<UInt8>, at offset: Int, before end: Int) -> Bool {
        offset + width <= end && lineBreakByte(in: bytes, at: offset) == Self.lineFeed
    }

    private func endsCharacter(in bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Bool {
        switch self {
        case .asciiCompatible:
            return bytes[offset] < Self.lowestByteInsideACharacter
        case .utf16LittleEndian:
            return offset + 1 < bytes.count && !Self.isHighSurrogateByte(bytes[offset + 1])
        case .utf16BigEndian:
            return offset + 1 < bytes.count && !Self.isHighSurrogateByte(bytes[offset])
        }
    }

    private static func isHighSurrogateByte(_ byte: UInt8) -> Bool {
        (0xD8...0xDB).contains(byte)
    }

    private func aligned(_ offset: Int, from start: Int) -> Int {
        start + ((offset - start) / width) * width
    }

    static let lowestByteInsideACharacter: UInt8 = 0x30

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    private static func lineBreak(_ byte: UInt8) -> UInt8? {
        byte == lineFeed || byte == carriageReturn ? byte : nil
    }
}
