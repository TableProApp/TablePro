import Foundation

public struct TabularTranscodingMap: Sendable {
    public let original: Data
    public let encoding: TabularTextEncoding
    let transcodedStarts: [Int]
    let originalStarts: [Int]

    public func originalOffsets(ofLineStarts ascendingOffsets: [Int], in transcoded: Data) -> [Int] {
        transcoded.withUnsafeBytes { transcodedRaw in
            original.withUnsafeBytes { originalRaw in
                originalOffsets(
                    of: ascendingOffsets,
                    transcoded: transcodedRaw.bindMemory(to: UInt8.self),
                    original: originalRaw.bindMemory(to: UInt8.self)
                )
            }
        }
    }

    private func originalOffsets(
        of ascendingOffsets: [Int],
        transcoded: UnsafeBufferPointer<UInt8>,
        original originalBytes: UnsafeBufferPointer<UInt8>
    ) -> [Int] {
        let layout = encoding.codeUnitLayout
        var checkpoint = 0
        var transcodedPosition = transcodedStarts[0]
        var originalPosition = originalStarts[0]
        var offsets: [Int] = []
        offsets.reserveCapacity(ascendingOffsets.count)
        for target in ascendingOffsets {
            guard target < transcoded.count else {
                offsets.append(originalBytes.count)
                continue
            }
            while checkpoint + 1 < transcodedStarts.count, transcodedStarts[checkpoint + 1] <= target {
                checkpoint += 1
                transcodedPosition = transcodedStarts[checkpoint]
                originalPosition = originalStarts[checkpoint]
            }
            let lineBreaks = TabularCodeUnitLayout.asciiCompatible.lineBreakCount(
                in: transcoded,
                from: transcodedPosition,
                to: target
            )
            originalPosition = layout.offset(afterLineBreaks: lineBreaks, in: originalBytes, from: originalPosition)
            transcodedPosition = target
            offsets.append(originalPosition)
        }
        return offsets
    }
}
