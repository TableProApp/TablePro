//
//  CellImagePreviewView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The rendered face of a cell that holds an image, shared by the grid popover, the row inspector
/// and the pop-out window.
internal struct CellImagePreviewView: View {
    let data: Data
    let format: CellImageFormat

    @State private var render: CellImageRender?

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .task(id: data) {
            render = nil
            render = await CellImageRenderer.render(data, format: format)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch render {
        case .none:
            ProgressView()
                .controlSize(.small)
        case .rendered(let image, _):
            CheckerboardBackground()
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFit()
                        .padding(8)
                }
                .accessibilityElement()
                .accessibilityLabel(String(localized: "Image preview"))
        case .tooLarge(let byteCount):
            ContentUnavailableView {
                Label(String(localized: "Too Large to Preview"), systemImage: "photo")
            } description: {
                Text(String(
                    format: String(localized: "This value is %@. The source is still readable."),
                    byteCount.formatted(.byteCount(style: .file))
                ))
            }
        case .failed:
            ContentUnavailableView {
                Label(String(localized: "Could Not Render This Image"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(String(
                    format: String(localized: "The value reads as %@, but drawing it did not finish."),
                    format.displayName
                ))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(format.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)

            if case .rendered(_, let pixelSize) = render, let pixelSize {
                Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(String(localized: "Copy Image")) { copyImage() }
                .controlSize(.small)
                .disabled(renderedImage == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var renderedImage: NSImage? {
        guard case .rendered(let image, _) = render else { return nil }
        return image
    }

    private func copyImage() {
        guard let image = renderedImage else { return }
        ClipboardService.shared.writeImage(image)
    }
}

/// Transparency has to be visible rather than guessed at, and a flat backing turns a transparent
/// logo into whichever colour the theme happens to use.
private struct CheckerboardBackground: View {
    private let squareSize: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let columns = Int((size.width / squareSize).rounded(.up))
            let rows = Int((size.height / squareSize).rounded(.up))
            for row in 0..<max(rows, 0) {
                for column in 0..<max(columns, 0) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(column) * squareSize,
                        y: CGFloat(row) * squareSize,
                        width: squareSize,
                        height: squareSize
                    )
                    context.fill(Path(rect), with: .color(Color(white: 0.88)))
                }
            }
        }
        .drawingGroup()
    }
}
