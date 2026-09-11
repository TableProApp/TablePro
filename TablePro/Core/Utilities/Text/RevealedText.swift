//
//  RevealedText.swift
//  TablePro
//

import CodeEditTextView
import Foundation

internal struct RevealedText: Equatable, Sendable {
    internal enum Segment: Equatable, Sendable {
        case text(String)
        case marker(label: String, spokenName: String)
        case blankSpace(String, spokenName: String)

        internal var shownText: String {
            switch self {
            case .text(let text), .blankSpace(let text, _):
                return text
            case .marker(let label, _):
                return "<\(label)>"
            }
        }
    }

    internal let segments: [Segment]

    internal init(_ text: String) {
        segments = Self.segments(of: text as NSString)
    }

    internal var revealsAnyCharacter: Bool {
        segments.contains { segment in
            guard case .text = segment else { return true }
            return false
        }
    }

    internal var plainText: String {
        segments.map(\.shownText).joined()
    }

    internal var spokenText: String {
        segments.map { segment in
            switch segment {
            case .text(let text):
                return text
            case .marker(_, let spokenName), .blankSpace(_, let spokenName):
                return " \(spokenName) "
            }
        }
        .joined()
    }
}

private extension RevealedText {
    static func segments(of text: NSString) -> [Segment] {
        var segments: [Segment] = []
        var runStart = 0
        var index = 0
        while index < text.length {
            guard let classified = SpecialCharacter.classify(in: text, at: index) else {
                index += 1
                continue
            }
            if index > runStart {
                segments.append(.text(text.substring(with: NSRange(location: runStart, length: index - runStart))))
            }
            segments.append(segment(for: classified, in: text))
            index = NSMaxRange(classified.range)
            runStart = index
        }
        if runStart < text.length {
            segments.append(.text(text.substring(from: runStart)))
        }
        return segments
    }

    static func segment(for classified: ClassifiedSpecialCharacter, in text: NSString) -> Segment {
        switch classified.character {
        case .marker(let label):
            return .marker(label: label, spokenName: classified.name)
        case .blankSpace:
            return .blankSpace(text.substring(with: classified.range), spokenName: classified.name)
        }
    }
}
