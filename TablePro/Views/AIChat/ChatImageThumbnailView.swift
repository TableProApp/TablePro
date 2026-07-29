//
//  ChatImageThumbnailView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct ChatImageThumbnailView: View {
    let input: ChatImageInput

    var body: some View {
        switch input.source {
        case .cacheFile(let filename, _):
            if let nsImage = AIImageCache.shared.loadImage(filename: filename) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        case .remoteURL(let url, _):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder
                case .empty:
                    ProgressView()
                @unknown default:
                    placeholder
                }
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.08))
    }
}
