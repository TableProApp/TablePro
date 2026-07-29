//
//  AIChatComposerImageChip.swift
//  TablePro
//

import SwiftUI

struct AIChatComposerImageChip: View {
    let input: ChatImageInput
    let onRemove: () -> Void

    private static let chipSize: CGFloat = 56

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ChatImageThumbnailView(input: input)
                .frame(width: Self.chipSize, height: Self.chipSize)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white, Color.black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(2)
            .accessibilityLabel(String(localized: "Remove image"))
        }
    }
}
