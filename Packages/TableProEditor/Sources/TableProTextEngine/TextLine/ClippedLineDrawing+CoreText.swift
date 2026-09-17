//
//  ClippedLineDrawing+CoreText.swift
//  TableProTextEngine
//

import AppKit
import CoreText

/// Reads a line's runs without copying them.
///
/// `CTLineGetGlyphRuns` hands back a `CFArray`, and bridging that array to a Swift array is O(runs). A long
/// highlighted line holds tens of thousands of runs and a draw touches a handful of them, so every reader here takes
/// the array and an index instead.
extension ClippedLineDrawing {
    static func run(in runs: CFArray, at index: Int) -> CTRun? {
        guard index >= 0, index < CFArrayGetCount(runs), let raw = CFArrayGetValueAtIndex(runs, index) else {
            return nil
        }
        let value = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        guard CFGetTypeID(value) == CTRunGetTypeID() else { return nil }
        return Unmanaged<CTRun>.fromOpaque(raw).takeUnretainedValue()
    }

    static func font(of run: CTRun) -> CTFont? {
        let attributes = CTRunGetAttributes(run)
        let key = Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()
        guard let raw = CFDictionaryGetValue(attributes, key) else { return nil }
        let value = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        guard CFGetTypeID(value) == CTFontGetTypeID() else { return nil }
        return Unmanaged<CTFont>.fromOpaque(raw).takeUnretainedValue()
    }

    static func firstX(ofRunIn runs: CFArray, at index: Int) -> CGFloat {
        guard let run = run(in: runs, at: index) else { return -.infinity }
        return firstX(of: run)
    }

    static func firstX(of run: CTRun) -> CGFloat {
        guard CTRunGetGlyphCount(run) > 0 else { return -.infinity }
        if let pointer = CTRunGetPositionsPtr(run) {
            return pointer.pointee.x
        }
        var point = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &point)
        return point.x
    }

    /// The index of the first glyph positioned past a threshold.
    static func firstIndex(in positions: UnsafeBufferPointer<CGPoint>, after threshold: CGFloat) -> Int {
        var low = 0
        var high = positions.count
        while low < high {
            let mid = (low + high) / 2
            if positions[mid].x > threshold {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    /// The index of the first glyph positioned at or past a threshold.
    static func firstIndex(in positions: UnsafeBufferPointer<CGPoint>, notBefore threshold: CGFloat) -> Int {
        var low = 0
        var high = positions.count
        while low < high {
            let mid = (low + high) / 2
            if positions[mid].x >= threshold {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    /// Hands a run's glyph positions to a closure, copying them only when Core Text will not lend them.
    static func withPositions<T>(
        of run: CTRun,
        glyphCount: Int,
        _ body: (UnsafeBufferPointer<CGPoint>) -> T
    ) -> T {
        if let pointer = CTRunGetPositionsPtr(run) {
            return body(UnsafeBufferPointer(start: pointer, count: glyphCount))
        }
        var storage = [CGPoint](repeating: .zero, count: glyphCount)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &storage)
        return storage.withUnsafeBufferPointer(body)
    }

    /// Hands a run's glyph advances to a closure, copying them only when Core Text will not lend them.
    static func withAdvances<T>(
        of run: CTRun,
        glyphCount: Int,
        _ body: (UnsafeBufferPointer<CGSize>) -> T
    ) -> T {
        if let pointer = CTRunGetAdvancesPtr(run) {
            return body(UnsafeBufferPointer(start: pointer, count: glyphCount))
        }
        var storage = [CGSize](repeating: .zero, count: glyphCount)
        CTRunGetAdvances(run, CFRange(location: 0, length: 0), &storage)
        return storage.withUnsafeBufferPointer(body)
    }

    /// Hands a run's string indices to a closure, copying them only when Core Text will not lend them.
    static func withStringIndices<T>(
        of run: CTRun,
        glyphCount: Int,
        _ body: (UnsafeBufferPointer<CFIndex>) -> T
    ) -> T {
        if let pointer = CTRunGetStringIndicesPtr(run) {
            return body(UnsafeBufferPointer(start: pointer, count: glyphCount))
        }
        var storage = [CFIndex](repeating: 0, count: glyphCount)
        CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &storage)
        return storage.withUnsafeBufferPointer(body)
    }
}
