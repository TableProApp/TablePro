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
    let symbol: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 17)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: .quaternarySystemFill))
                )
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
