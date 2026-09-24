import Foundation

public struct TabularCancellation: Error, Equatable, Sendable {
    public init() {}
}

public struct DelimitedRowIndex: Sendable {
    public let rowStarts: [Int]
    public let contentStart: Int
    public let endOffset: Int
    public let endsWithLineTerminator: Bool

    public var rowCount: Int { rowStarts.count }

    public func range(ofRow row: Int) -> Range<Int> {
        let start = rowStarts[row]
        let end = row + 1 < rowStarts.count ? rowStarts[row + 1] : endOffset
        return start..<end
    }
}

public enum DelimitedRowIndexer {
    private static let progressStride = 1 << 24

    public static func index(
        _ bytes: UnsafeBufferPointer<UInt8>,
        dialect: DelimitedDialect,
        contentStart: Int,
        progress: ((Double) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> DelimitedRowIndex {
        let count = bytes.count
        let start = min(contentStart, count)
        guard let base = bytes.baseAddress, start < count else {
            return DelimitedRowIndex(rowStarts: [], contentStart: start, endOffset: count, endsWithLineTerminator: false)
        }
        var starts: [Int] = []
        starts.reserveCapacity(max(16, (count - start) / 64))
        let quote = dialect.quote
        let escape = dialect.escape
        let delimiter = dialect.delimiter
        let escapeDiffers = escape != quote
        let quoteMask = broadcast(quote)
        let escapeMask = broadcast(escape)
        let lineFeedMask = broadcast(0x0A)
        let carriageReturnMask = broadcast(0x0D)
        var index = start
        var rowStart = start
        var nextCheckpoint = start + progressStride

        while index < count {
            if index >= nextCheckpoint {
                if isCancelled() { throw TabularCancellation() }
                progress?(Double(index) / Double(count))
                nextCheckpoint = index + progressStride
            }
            while index + 8 <= count {
                let word = UnsafeRawPointer(base + index).loadUnaligned(as: UInt64.self)
                let hits = zeroBytes(word ^ quoteMask) | zeroBytes(word ^ lineFeedMask)
                    | zeroBytes(word ^ carriageReturnMask)
                if hits == 0 {
                    index += 8
                    continue
                }
                index += hits.trailingZeroBitCount >> 3
                break
            }
            if index >= count { break }
            let byte = base[index]
            if byte == 0x0A {
                index += 1
                starts.append(rowStart)
                rowStart = index
                continue
            }
            if byte == 0x0D {
                index += 1
                if index < count, base[index] == 0x0A { index += 1 }
                starts.append(rowStart)
                rowStart = index
                continue
            }
            if byte != quote {
                index += 1
                continue
            }
            let opensField = index == rowStart || base[index - 1] == delimiter
            index += 1
            guard opensField else { continue }
            inside: while index < count {
                while index + 8 <= count {
                    let word = UnsafeRawPointer(base + index).loadUnaligned(as: UInt64.self)
                    let hits = escapeDiffers
                        ? (zeroBytes(word ^ quoteMask) | zeroBytes(word ^ escapeMask))
                        : zeroBytes(word ^ quoteMask)
                    if hits == 0 {
                        index += 8
                        continue
                    }
                    index += hits.trailingZeroBitCount >> 3
                    break
                }
                if index >= count { break }
                let inner = base[index]
                if escapeDiffers, inner == escape, index + 1 < count {
                    index += 2
                    continue
                }
                if inner == quote {
                    if !escapeDiffers, index + 1 < count, base[index + 1] == quote {
                        index += 2
                        continue
                    }
                    index += 1
                    break inside
                }
                index += 1
            }
        }
        let endsWithTerminator = rowStart == count
        if rowStart < count {
            starts.append(rowStart)
        }
        progress?(1)
        return DelimitedRowIndex(
            rowStarts: starts,
            contentStart: start,
            endOffset: count,
            endsWithLineTerminator: endsWithTerminator
        )
    }

    @inline(__always)
    private static func broadcast(_ byte: UInt8) -> UInt64 {
        UInt64(byte) &* 0x0101_0101_0101_0101
    }

    @inline(__always)
    private static func zeroBytes(_ word: UInt64) -> UInt64 {
        (word &- 0x0101_0101_0101_0101) & ~word & 0x8080_8080_8080_8080
    }
}
