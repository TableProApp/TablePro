//
//  AIChatImageBlockView.swift
//  TablePro
//

import SwiftUI

struct AIChatImageBlockView: View {
    let input: ChatImageInput

    private static let thumbnailSize: CGFloat = 96

    var body: some View {
        ChatImageThumbnailView(input: input)
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }
}
