//
//  TextView+createReadBlock.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 5/20/23.
//

import _RopeModule
import Foundation
import SwiftTreeSitter
import TableProTextEngine

/// The document's UTF-16 text as immutable chunks in a rope.
///
/// A parse off the main thread reads a copy, so the text cannot change between its time slices. Copying shares every
/// chunk, and an edit replaces only the chunks it touches, so the main thread hands a parse its text in
/// O(log n) instead of copying the document on every key.
struct TextSnapshot: Sendable {
    /// Chunks stay between `minChunkLength` and `maxChunkLength` units when an edit rebuilds them, so a read hands
    /// tree-sitter a few kilobytes at a time and an edit copies at most a few chunks.
    static let maxChunkLength = TreeSitterClient.Constants.charsToReadInBlock
    static let minChunkLength = maxChunkLength / 4

    private var rope: Rope<TextChunk>

    var length: Int {
        rope.count(in: TextChunk.Metric())
    }

    init(string: NSString) {
        self.rope = Rope(Self.chunks(of: string, in: NSRange(location: 0, length: string.length)))
    }

    /// Replaces `range`, in the text as it was before the edit, with the characters `source` now holds in
    /// `replacement`.
    mutating func replace(_ range: NSRange, with source: NSString, in replacement: NSRange) {
        let metric = TextChunk.Metric()
        guard !rope.isEmpty else {
            rope = Rope(Self.chunks(of: source, in: replacement))
            return
        }
        // Widen the edit to whole chunks, so the rope never splits one and small edits do not leave slivers behind.
        let (startIndex, startRemaining) = rope.find(at: range.location, in: metric, preferEnd: true)
        let spanStart = range.location - startRemaining
        let (endIndex, endRemaining) = rope.find(at: range.max, in: metric, preferEnd: true)
        var spanEnd = range.max - endRemaining + rope[endIndex].count
        let prefix = rope[startIndex].units(from: 0, to: startRemaining)
        let suffix = rope[endIndex].units(from: endRemaining, to: rope[endIndex].count)
        // A chunk left short by a deletion takes in its neighbor.
        var neighbor: UnsafeBufferPointer<UInt16>?
        let next = rope.index(after: endIndex)
        if prefix.count + replacement.length + suffix.count < Self.minChunkLength, next < rope.endIndex {
            neighbor = rope[next].units(from: 0, to: rope[next].count)
            spanEnd += rope[next].count
        }

        var units = ContiguousArray<UInt16>()
        units.reserveCapacity(prefix.count + replacement.length + suffix.count + (neighbor?.count ?? 0))
        units.append(contentsOf: prefix)
        if replacement.length > 0 {
            let start = units.count
            units.append(contentsOf: repeatElement(0, count: replacement.length))
            units.withUnsafeMutableBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    source.getCharacters(base + start, range: replacement)
                }
            }
        }
        units.append(contentsOf: suffix)
        if let neighbor {
            units.append(contentsOf: neighbor)
        }
        rope.replaceSubrange(spanStart..<spanEnd, in: metric, with: Self.chunks(of: units))
    }

    /// The bytes tree-sitter reads at `byteOffset`: the rest of the chunk holding it, without copying.
    var readBlock: Parser.ReadBlock {
        { [self] byteOffset, _ in
            let location = byteOffset / 2
            let length = self.length
            guard location <= length else { return nil }
            guard location < length else { return Data() }
            let (index, remaining) = rope.find(at: location, in: TextChunk.Metric(), preferEnd: false)
            return rope[index].data(from: remaining)
        }
    }

    var readCallback: SwiftTreeSitter.Predicate.TextProvider {
        { [self] range, _ in
            string(in: range)
        }
    }

    func string(in range: NSRange) -> String? {
        guard range.location >= 0, range.length >= 0, range.max <= length else { return nil }
        guard range.length > 0 else { return "" }
        var units = ContiguousArray<UInt16>()
        units.reserveCapacity(range.length)
        var (index, offset) = rope.find(at: range.location, in: TextChunk.Metric(), preferEnd: false)
        while units.count < range.length, index < rope.endIndex {
            let chunk = rope[index]
            let end = min(chunk.count, offset + range.length - units.count)
            units.append(contentsOf: chunk.units(from: offset, to: end))
            offset = 0
            index = rope.index(after: index)
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func chunks(of string: NSString, in range: NSRange) -> [TextChunk] {
        stride(from: range.location, to: range.max, by: maxChunkLength).map { location in
            let chunkRange = NSRange(location: location, length: min(maxChunkLength, range.max - location))
            return TextChunk(count: chunkRange.length) { base in
                string.getCharacters(base, range: chunkRange)
            }
        }
    }

    private static func chunks(of units: ContiguousArray<UInt16>) -> [TextChunk] {
        guard !units.isEmpty else { return [] }
        // Even pieces, so a long paste does not end in a sliver.
        let pieces = (units.count + maxChunkLength - 1) / maxChunkLength
        let base = units.count / pieces
        let extra = units.count % pieces
        var chunks: [TextChunk] = []
        chunks.reserveCapacity(pieces)
        var start = 0
        units.withUnsafeBufferPointer { buffer in
            for piece in 0..<pieces {
                let count = base + (piece < extra ? 1 : 0)
                let slice = UnsafeBufferPointer(rebasing: buffer[start..<(start + count)])
                chunks.append(TextChunk(count: count) { destination in
                    if let source = slice.baseAddress {
                        destination.update(from: source, count: count)
                    }
                })
                start += count
            }
        }
        return chunks
    }
}

/// UTF-16 units that never change once written, so a snapshot on another thread can read them while the main thread
/// edits its own copy of the rope.
private final class TextChunkStorage: @unchecked Sendable {
    let units: UnsafeMutableBufferPointer<UInt16>

    init(count: Int, fill: (UnsafeMutablePointer<UInt16>) -> Void) {
        units = .allocate(capacity: count)
        if let base = units.baseAddress {
            fill(base)
        }
    }

    deinit {
        units.deallocate()
    }
}

private struct TextChunk: RopeElement, Sendable {
    typealias Index = Int

    private let storage: TextChunkStorage

    init(count: Int, fill: (UnsafeMutablePointer<UInt16>) -> Void) {
        storage = TextChunkStorage(count: count, fill: fill)
    }

    var count: Int { storage.units.count }

    func units(from start: Int, to end: Int) -> UnsafeBufferPointer<UInt16> {
        UnsafeBufferPointer(rebasing: storage.units[start..<end])
    }

    // The storage outlives the Data: the snapshot the read block captures holds the chunk.
    func data(from start: Int) -> Data {
        guard start < count, let base = storage.units.baseAddress else { return Data() }
        return Data(
            bytesNoCopy: UnsafeMutableRawPointer(base + start),
            count: (count - start) * MemoryLayout<UInt16>.size,
            deallocator: .none
        )
    }

    var summary: Summary { Summary(length: count) }

    var isEmpty: Bool { storage.units.isEmpty }

    // `replace` sizes its chunks itself, so the rope never rebalances them.
    var isUndersized: Bool { false }

    func invariantCheck() {}

    mutating func rebalance(nextNeighbor right: inout TextChunk) -> Bool {
        false
    }

    mutating func split(at index: Int) -> TextChunk {
        let head = units(from: 0, to: index)
        let tail = units(from: index, to: count)
        let tailChunk = TextChunk(count: tail.count) { destination in
            if let source = tail.baseAddress {
                destination.update(from: source, count: tail.count)
            }
        }
        self = TextChunk(count: head.count) { destination in
            if let source = head.baseAddress {
                destination.update(from: source, count: head.count)
            }
        }
        return tailChunk
    }

    struct Summary: RopeSummary {
        var length: Int

        static var maxNodeSize: Int { 15 }

        static var zero: Summary { Summary(length: 0) }

        var isZero: Bool { length == 0 }

        mutating func add(_ other: Summary) {
            length += other.length
        }

        mutating func subtract(_ other: Summary) {
            length -= other.length
        }
    }

    struct Metric: RopeMetric {
        typealias Element = TextChunk

        func size(of summary: Summary) -> Int {
            summary.length
        }

        func index(at offset: Int, in element: TextChunk) -> Int {
            offset
        }
    }
}

extension TextView {
    func createTextSnapshot() -> TextSnapshot {
        TextSnapshot(string: textStorage.mutableString)
    }
}
