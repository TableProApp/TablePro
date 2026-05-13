//
//  VimEngine+Search.swift
//  TablePro
//

import Foundation

extension VimEngine {
    func runSearch(pattern: String, forward: Bool) {
        guard !pattern.isEmpty, let buffer else { return }
        lastSearchPattern = pattern
        lastSearchForward = forward
        let origin = buffer.selectedRange().location
        if let target = findPattern(pattern, from: origin, forward: forward, wholeWord: false, in: buffer) {
            buffer.setSelectedRange(NSRange(location: target, length: 0))
            lastJumpOrigin = origin
        }
    }

    func searchNext(in buffer: VimTextBuffer, reverseDirection: Bool) {
        guard let pattern = lastSearchPattern else { return }
        let forward = reverseDirection ? !lastSearchForward : lastSearchForward
        let origin = buffer.selectedRange().location
        if let target = findPattern(pattern, from: origin, forward: forward, wholeWord: false, in: buffer) {
            buffer.setSelectedRange(NSRange(location: target, length: 0))
            lastJumpOrigin = origin
        }
    }

    func searchWordUnderCursor(forward: Bool, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        guard pos < buffer.length else { return }
        var start = pos
        while start > 0 && isWordChar(buffer.character(at: start - 1)) { start -= 1 }
        var end = pos
        while end < buffer.length && isWordChar(buffer.character(at: end)) { end += 1 }
        guard end > start else { return }
        let word = buffer.string(in: NSRange(location: start, length: end - start))
        lastSearchPattern = word
        lastSearchForward = forward
        let origin = pos
        if let target = findPattern(word, from: origin, forward: forward, wholeWord: true, in: buffer) {
            buffer.setSelectedRange(NSRange(location: target, length: 0))
            lastJumpOrigin = origin
        }
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
