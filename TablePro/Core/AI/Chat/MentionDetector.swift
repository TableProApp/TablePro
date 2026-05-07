//
//  MentionDetector.swift
//  TablePro
//

import Foundation

struct MentionMatch: Equatable, Sendable {
    let range: NSRange
    let query: String
}

enum MentionDetector {
    static func detect(in text: String, caret: Int) -> MentionMatch? {
        let nsText = text as NSString
        guard caret >= 0, caret <= nsText.length else { return nil }

        var idx = caret - 1
        while idx >= 0 {
            let c = nsText.character(at: idx)
            if c == 0x40 {
                guard isBoundary(before: idx, in: nsText) else { return nil }
                let queryStart = idx + 1
                let queryLength = caret - queryStart
                let query = nsText.substring(with: NSRange(location: queryStart, length: queryLength))
                return MentionMatch(
                    range: NSRange(location: idx, length: caret - idx),
                    query: query
                )
            }
            if !isQueryCharacter(c) {
                return nil
            }
            idx -= 1
        }
        return nil
    }

    private static func isQueryCharacter(_ c: unichar) -> Bool {
        if c >= 0x41 && c <= 0x5A { return true }
        if c >= 0x61 && c <= 0x7A { return true }
        if c >= 0x30 && c <= 0x39 { return true }
        if c == 0x5F { return true }
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    private static func isBoundary(before idx: Int, in nsText: NSString) -> Bool {
        guard idx > 0 else { return true }
        let prev = nsText.character(at: idx - 1)
        guard let scalar = Unicode.Scalar(prev) else { return true }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
        if CharacterSet.punctuationCharacters.contains(scalar) { return true }
        return false
    }
}
