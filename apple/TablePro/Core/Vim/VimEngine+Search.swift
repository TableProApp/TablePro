//
//  VimEngine+Search.swift
//  TablePro
//

import Foundation

extension VimEngine {
    func runSearch(pattern: String, forward: Bool, count: Int = 1) {
        guard let buffer else { return }
        let origin = buffer.selectedRange().location
        if let target = searchTarget(pattern: pattern, forward: forward, count: count, in: buffer) {
            buffer.setSelectedRange(NSRange(location: target, length: 0))
            lastJumpOrigin = origin
        }
    }

    // Remembers the pattern for `n` and `N`, as a search does even when nothing matches.
    func searchTarget(pattern: String, forward: Bool, count: Int = 1, in buffer: VimTextBuffer) -> Int? {
        guard !pattern.isEmpty else { return nil }
        lastSearchPattern = pattern
        lastSearchForward = forward
        var position = buffer.selectedRange().location
        for _ in 0..<max(1, count) {
            guard let next = findPattern(pattern, from: position, forward: forward, wholeWord: false, in: buffer) else {
                return nil
            }
            position = next
        }
        return position
    }

    func searchNextTarget(count: Int, reverseDirection: Bool, in buffer: VimTextBuffer) -> Int? {
        guard let pattern = lastSearchPattern else { return nil }
        let forward = reverseDirection ? !lastSearchForward : lastSearchForward
        var position = buffer.selectedRange().location
        for _ in 0..<max(1, count) {
            guard let next = findPattern(pattern, from: position, forward: forward, wholeWord: false, in: buffer) else {
                return nil
            }
            position = next
        }
        return position
    }

    func searchWordUnderCursorTarget(forward: Bool, count: Int, in buffer: VimTextBuffer) -> Int? {
        let pos = buffer.selectedRange().location
        guard pos < buffer.length else { return nil }
        var start = pos
        while start > 0 && isWordCharacter(at: start - 1, in: buffer) { start -= 1 }
        var end = pos
        while end < buffer.length && isWordCharacter(at: end, in: buffer) { end += 1 }
        guard end > start else { return nil }
        let word = buffer.string(in: NSRange(location: start, length: end - start))
        lastSearchPattern = word
        lastSearchForward = forward
        var position = pos
        for _ in 0..<max(1, count) {
            guard let next = findPattern(word, from: position, forward: forward, wholeWord: true, in: buffer) else {
                return nil
            }
            position = next
        }
        return position
    }

    func findPattern(
        _ pattern: String,
        from origin: Int,
        forward: Bool,
        wholeWord: Bool,
        in buffer: VimTextBuffer
    ) -> Int? {
        let total = buffer.length
        guard total > 0 else { return nil }
        let nsBuffer = buffer.string(in: NSRange(location: 0, length: total)) as NSString
        let needle = pattern as NSString
        guard needle.length > 0 else { return nil }
        let matches: (Int) -> Bool = { idx in
            guard idx + needle.length <= total else { return false }
            let candidate = nsBuffer.substring(with: NSRange(location: idx, length: needle.length))
            guard candidate == pattern else { return false }
            if !wholeWord { return true }
            let beforeOk = idx == 0 || !self.isWordChar(nsBuffer.character(at: idx - 1))
            let afterIdx = idx + needle.length
            let afterOk = afterIdx >= total || !self.isWordChar(nsBuffer.character(at: afterIdx))
            return beforeOk && afterOk
        }

        if forward {
            var i = origin + 1
            while i < total {
                if matches(i) { return i }
                i += 1
            }
            i = 0
            while i < origin {
                if matches(i) { return i }
                i += 1
            }
            if matches(origin) { return origin }
        } else {
            var i = origin - 1
            while i >= 0 {
                if matches(i) { return i }
                i -= 1
            }
            i = total - 1
            while i > origin {
                if matches(i) { return i }
                i -= 1
            }
            if matches(origin) { return origin }
        }
        return nil
    }

    func isWordChar(_ ch: unichar) -> Bool {
        if ch == 0x5F { return true }
        guard let scalar = UnicodeScalar(ch) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}
