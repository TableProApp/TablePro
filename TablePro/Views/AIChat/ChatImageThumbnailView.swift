//
//  ChatImageThumbnailView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct ChatImageThumbnailView: View {
    let input: ChatImageInput

    /// The largest frame a thumbnail is drawn in, in points.
    private static let maximumPointSize: CGFloat = 96

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?

    var body: some View {
        switch input.source {
        case .cacheFile(let filename, _):
            let maxPixelSize = Int(Self.maximumPointSize * displayScale)
            Group {
                if let thumbnail = thumbnail
                    ?? AIImageCache.shared.cachedThumbnail(filename: filename, maxPixelSize: maxPixelSize) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .task(id: filename) {
                thumbnail = await Self.loadThumbnail(filename: filename, maxPixelSize: maxPixelSize)
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

    /// Decoding happens off the main actor; a row that scrolls back in finds the thumbnail in the cache.
    @concurrent
    nonisolated private static func loadThumbnail(filename: String, maxPixelSize: Int) async -> NSImage? {
        AIImageCache.shared.thumbnail(filename: filename, maxPixelSize: maxPixelSize)
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .quaternaryFill))
    }
}
