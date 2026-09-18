//
//  RevealedTextView.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct RevealedTextView: View {
    private let text: String
    private let revealed: RevealedText

    internal init(_ text: String) {
        self.text = text
        revealed = RevealedText(text)
    }

    internal var body: some View {
        if revealed.revealsAnyCharacter {
            Text(revealed.styledText)
                .accessibilityRepresentation {
                    Text(verbatim: revealed.spokenText)
                }
        } else {
            Text(verbatim: text)
        }
    }
}

internal extension RevealedText {
    static let markColor = Color(nsColor: .systemOrange)
    static let markBackground = markColor.opacity(0.18)
    static let blankSpaceBackground = markColor.opacity(0.4)

    var styledText: AttributedString {
        segments.reduce(into: AttributedString()) { styled, segment in
            var run = AttributedString(segment.shownText)
            switch segment {
            case .text:
                break
            case .marker:
                run.foregroundColor = Self.markColor
                run.backgroundColor = Self.markBackground
            case .blankSpace:
                run.backgroundColor = Self.blankSpaceBackground
            }
            styled += run
        }
    }
}
