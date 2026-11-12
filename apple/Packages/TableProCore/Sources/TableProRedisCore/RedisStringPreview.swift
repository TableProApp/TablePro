import Foundation

nonisolated public enum RedisStringPreview {
    // Holds a grid page to its row count times 64 KiB, where reading each string whole had no bound.
    public static let byteLimit = 65_536

    // The mark JSONTruncation puts after a cut value.
    public static let marker = "..."

    public enum Shown: Equatable, Sendable {
        case text(String)
        case bytes(Data)
    }

    // STRLEN declined leaves only the read itself, and a read that filled the range may have been cut.
    public static func isShortened(length: Int?, shownByteCount: Int, byteLimit: Int = RedisStringPreview.byteLimit) -> Bool {
        guard let length else { return shownByteCount >= byteLimit }
        return length > byteLimit
    }

    public static func shown(_ bytes: Data, length: Int?, byteLimit: Int = RedisStringPreview.byteLimit) -> Shown {
        guard isShortened(length: length, shownByteCount: bytes.count, byteLimit: byteLimit) else {
            return RedisWireText.decode(bytes).map(Shown.text) ?? .bytes(bytes)
        }
        guard let text = RedisWireText.decode(wholeSequencePrefix(bytes)) else { return .bytes(bytes) }
        return .text(text + marker)
    }

    // Drops only a multi-byte sequence the range cut through, so a binary value never passes as text.
    static func wholeSequencePrefix(_ bytes: Data) -> Data {
        let tail = Array(bytes.suffix(3))
        for offset in stride(from: 1, through: tail.count, by: 1) {
            let byte = tail[tail.count - offset]
            if byte & 0xC0 == 0x80 { continue }
            let sequenceLength: Int
            switch byte {
            case 0xC0...0xDF: sequenceLength = 2
            case 0xE0...0xEF: sequenceLength = 3
            case 0xF0...0xF7: sequenceLength = 4
            default: return bytes
            }
            return offset < sequenceLength ? Data(bytes.prefix(bytes.count - offset)) : bytes
        }
        return bytes
    }
}
