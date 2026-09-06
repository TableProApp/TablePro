//
//  CellImageViewer.swift
//  TablePro
//

import SwiftUI

internal enum CellImageViewMode: Hashable {
    case image
    case source
}

/// Which form the segment beside the picture shows, decided by how the cell stores the value rather
/// than by what the value turned out to be. An SVG document held as bytes in a binary column is a
/// blob whose readable form is its dump, and it has to read that way in the popover, the row
/// inspector and the pop-out window alike.
internal enum CellImageSourceKind: Hashable {
    case markup
    case hex

    var label: String {
        switch self {
        case .markup:
            return String(localized: "Source")
        case .hex:
            return String(localized: "Hex")
        }
    }
}

/// A cell whose content is an image, with its stored form one segment away.
///
/// The stored form is the caller's, because it differs by where the value came from: a hex dump for
/// a binary column, the markup for SVG in a text column. Everything else about the two panes is the
/// same wherever this appears, which is what keeps the popover, the row inspector and the pop-out
/// window from drifting apart.
internal struct CellImageViewer<Source: View>: View {
    /// A closure rather than the bytes, so an editable source pane does not copy the whole document
    /// on every keystroke to feed a pane that is not on screen. It is read when the image segment
    /// builds, which is also what makes switching back to it show the edits.
    let data: () -> Data
    let format: CellImageFormat
    let sourceKind: CellImageSourceKind
    var onPopOut: (() -> Void)?
    @ViewBuilder let source: () -> Source

    @State private var mode: CellImageViewMode = .image

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker(String(localized: "View Mode"), selection: $mode) {
                Text(String(localized: "Image")).tag(CellImageViewMode.image)
                Text(sourceKind.label).tag(CellImageViewMode.source)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            if let onPopOut {
                Button { onPopOut() } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Open in Window"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .image:
            CellImagePreviewView(data: data(), format: format)
        case .source:
            source()
        }
    }
}
