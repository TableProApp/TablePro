//
//  AIChatContextChipView.swift
//  TablePro
//

import SwiftUI

struct AIChatContextChipView: View {
    let item: ContextItem
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: item.symbolName)
                .font(.caption2)
            Text(item.displayLabel)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "Remove attachment"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
    }
}

struct AIChatContextChipStrip: View {
    let items: [ContextItem]
    var onRemove: ((ContextItem) -> Void)?

    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.stableKey) { item in
                        let removeAction: (() -> Void)? = onRemove.map { handler in { handler(item) } }
                        AIChatContextChipView(item: item, onRemove: removeAction)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }
}
