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

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            suggestion.image
                .font(.system(size: font.pointSize + 2))
                .foregroundStyle(
                    .white,
                    suggestion.deprecated ? .gray : suggestion.imageColor
                )

            // Main label
            HStack(spacing: font.charWidth) {
                Text(suggestion.label)
                    .foregroundStyle(suggestion.deprecated ? Color(secondaryLabelColor) : Color(labelColor))

                if let detail = suggestion.detail {
                    Text(detail)
                        .foregroundStyle(Color(secondaryLabelColor))
                }
            }
            .font(Font(font))

            Spacer(minLength: 0)

            // Right side indicators
            if suggestion.deprecated {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: font.pointSize + 2))
                    .foregroundStyle(Color(labelColor), Color(secondaryLabelColor))
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, Self.HORIZONTAL_PADDING)
        .buttonStyle(PlainButtonStyle())
    }
}
