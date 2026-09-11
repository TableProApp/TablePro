//
//  SpecialCharacterDisplay.swift
//  CodeEditTextView
//

import AppKit

struct SpecialCharacterDisplay {
    static let objectReplacementCharacter = "\u{FFFC}"
    static let clusterExtender = "\u{034F}"
    static let wordJoiner = "\u{2060}"

    let string: NSAttributedString
    let marks: [SpecialCharacterMark]

    static func make(from string: NSAttributedString, style: SpecialCharacterStyle?) -> SpecialCharacterDisplay {
        guard string.length > 0 else {
            return SpecialCharacterDisplay(string: string, marks: [])
        }
        let text = string.string as NSString
        var builder = Builder(source: string)
        var neutralizeFrom = 0
        if let style, style.maximumMarksPerLine > 0 {
            neutralizeFrom = builder.markSpecialCharacters(in: text, style: style)
        }
        builder.neutralizeLayoutControls(in: text, from: neutralizeFrom)
        return builder.display
    }
}

private extension SpecialCharacterDisplay {
    struct Builder {
        let source: NSAttributedString
        private(set) var marks: [SpecialCharacterMark] = []
        private var substituted: NSMutableAttributedString?

        init(source: NSAttributedString) {
            self.source = source
        }

        var display: SpecialCharacterDisplay {
            SpecialCharacterDisplay(string: substituted ?? source, marks: marks)
        }

        mutating func markSpecialCharacters(in text: NSString, style: SpecialCharacterStyle) -> Int {
            var index = 0
            while index < text.length {
                guard marks.count < style.maximumMarksPerLine else { return index }
                guard let classified = SpecialCharacter.classify(in: text, at: index) else {
                    index += 1
                    continue
                }
                add(classified, color: style.color)
                index = NSMaxRange(classified.range)
            }
            return index
        }

        mutating func neutralizeLayoutControls(in text: NSString, from start: Int) {
            var searchStart = start
            while searchStart < text.length {
                let searchRange = NSRange(location: searchStart, length: text.length - searchStart)
                let found = text.rangeOfCharacter(
                    from: SpecialCharacter.layoutControls,
                    options: .literal,
                    range: searchRange
                )
                guard found.location != NSNotFound else { return }
                mutableCopy().replaceCharacters(in: found, with: SpecialCharacterDisplay.wordJoiner)
                searchStart = NSMaxRange(found)
            }
        }

        private mutating func add(_ classified: ClassifiedSpecialCharacter, color: NSColor) {
            let range = classified.range
            let font = font(at: range.location)
            if case .marker(let label) = classified.character {
                guard reserveMarker(label: label, font: font, in: range) else { return }
            }
            marks.append(SpecialCharacterMark(
                offset: range.location,
                length: range.length,
                character: classified.character,
                font: font,
                color: color
            ))
        }

        private func font(at index: Int) -> NSFont {
            source.attribute(.font, at: index, effectiveRange: nil) as? NSFont
                ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        private mutating func mutableCopy() -> NSMutableAttributedString {
            if let substituted {
                return substituted
            }
            let copy = NSMutableAttributedString(attributedString: source)
            substituted = copy
            return copy
        }

        private mutating func reserveMarker(label: String, font: NSFont, in range: NSRange) -> Bool {
            guard let delegate = SpecialCharacterMetrics.markerDelegate(label: label, font: font) else {
                return false
            }
            let target = mutableCopy()
            let placeholder = SpecialCharacterDisplay.objectReplacementCharacter
                + String(repeating: SpecialCharacterDisplay.clusterExtender, count: range.length - 1)
            target.replaceCharacters(in: range, with: placeholder)
            target.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
            target.addAttribute(
                NSAttributedString.Key(kCTRunDelegateAttributeName as String),
                value: delegate,
                range: NSRange(location: range.location, length: 1)
            )
            return true
        }
    }
}
