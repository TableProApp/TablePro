//
//  AIChatContextChipView.swift
//  TablePro
//

import SwiftUI

struct AIChatContextChipView: View {
    let item: ContextItem
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            Label(item.displayLabel, systemImage: item.symbolName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            if let onRemove {
                Button(String(localized: "Remove attachment"), systemImage: "xmark", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .help(item.helpText ?? item.displayLabel)
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
