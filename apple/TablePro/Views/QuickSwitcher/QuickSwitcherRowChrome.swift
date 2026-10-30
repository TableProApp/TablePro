//
//  QuickSwitcherRowChrome.swift
//  TablePro
//

import SwiftUI

/// The pieces of a floating panel's rows that every panel draws the same way: the bold run over the
/// characters a fuzzy match hit, and the key glyph beside a footer label.
internal enum QuickSwitcherRowChrome {
    static func highlightedName(_ name: String, matchedIndices: [Int]) -> AttributedString {
        var attributed = AttributedString(name)
        guard !matchedIndices.isEmpty else { return attributed }
        let characterIndices = Array(attributed.characters.indices)
        for index in matchedIndices where index < characterIndices.count {
            let start = characterIndices[index]
            let end = attributed.characters.index(after: start)
            attributed[start..<end].font = .body.weight(.semibold)
        }
        return attributed
    }
}

internal struct QuickSwitcherKeyHint: View {
    enum Glyph {
        case text(String)
        case symbol(String)

        // The system font has no U+21A9: its first draw in a process loads a fallback font, about 10 ms.
        static let returnKey = Glyph.symbol("return")
    }

    let keys: [Glyph]
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 1) {
                ForEach(keys.indices, id: \.self) { index in
                    switch keys[index] {
                    case .text(let text):
                        Text(text)
                    case .symbol(let name):
                        Image(systemName: name)
                    }
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 17)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .quaternaryFill))
            )
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
