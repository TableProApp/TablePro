//
//  CodeSuggestionLabelView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/24/25.
//

import AppKit
import SwiftUI

struct CodeSuggestionLabelView: View {
    static let HORIZONTAL_PADDING: CGFloat = 13

    let suggestion: CodeSuggestionEntry
    let labelColor: NSColor
    let secondaryLabelColor: NSColor
    let font: NSFont
    var isSelected: Bool = false

    private var effectiveLabelColor: Color {
        if isSelected {
            return .white
        }
        return suggestion.deprecated ? Color(secondaryLabelColor) : Color(labelColor)
    }

    private var effectiveSecondaryColor: Color {
        if isSelected {
            return Color.white.opacity(0.7)
        }
        return Color(secondaryLabelColor)
    }

    // swiftlint:disable shorthand_operator
    private func highlightedLabel() -> Text {
        let label = suggestion.label
        let ranges = suggestion.matchedRanges
        let color = effectiveLabelColor

        guard !ranges.isEmpty else {
            return Text(label).foregroundColor(color)
        }

        var result = Text("")
        var currentIndex = 0

        for range in ranges {
            let clampedUpper = min(range.upperBound, label.count)
            guard range.lowerBound < clampedUpper else { continue }

            if currentIndex < range.lowerBound {
                let start = label.index(label.startIndex, offsetBy: currentIndex)
                let end = label.index(label.startIndex, offsetBy: range.lowerBound)
                result = result + Text(label[start..<end]).foregroundColor(color)
            }

            let start = label.index(label.startIndex, offsetBy: range.lowerBound)
            let end = label.index(label.startIndex, offsetBy: clampedUpper)
            result = result + Text(label[start..<end]).foregroundColor(color).bold()
            currentIndex = clampedUpper
        }

        if currentIndex < label.count {
            let start = label.index(label.startIndex, offsetBy: currentIndex)
            result = result + Text(label[start...]).foregroundColor(color)
        }

        return result
    }
    // swiftlint:enable shorthand_operator

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            suggestion.image
                .font(.system(size: font.pointSize + 2))
                .foregroundStyle(
                    .white,
                    suggestion.deprecated ? .gray : suggestion.imageColor
                )

            HStack(spacing: font.charWidth) {
                highlightedLabel()

                if let detail = suggestion.detail {
                    Text(detail)
                        .foregroundStyle(effectiveSecondaryColor)
                }
            }
            .font(Font(font))

            Spacer(minLength: 0)

            if suggestion.deprecated {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: font.pointSize + 2))
                    .foregroundStyle(effectiveLabelColor, effectiveSecondaryColor)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, Self.HORIZONTAL_PADDING)
        .buttonStyle(PlainButtonStyle())
    }
}
