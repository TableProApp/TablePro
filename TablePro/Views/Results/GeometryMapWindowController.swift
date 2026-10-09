//
//  GeometryMapWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The pop-out window for a geometry value's map. Read-only on purpose: the text stays with the
/// row inspector, which is the place that can record a change to it.
@MainActor
internal final class GeometryMapWindowController: ValueViewerWindowController {
    static func open(text: String, source: GeometryFieldSource, columnName: String) {
        let preview = GeometryFieldPreview.readsSynchronously(text)
            ? GeometryFieldPreview.make(text: text, source: source, state: .value(text))
            : nil

        let controller = GeometryMapWindowController()
        controller.present(
            identifier: "geometry-map-viewer",
            title: String(format: String(localized: "Geometry: %@"), columnName),
            autosaveName: "GeometryMapViewerWindow"
        ) { _ in
            GeometryMapWindowContent(text: text, source: source, initialPreview: preview)
        }
    }
}

private struct GeometryMapWindowContent: View {
    let text: String
    let source: GeometryFieldSource

    /// Nil while a large value is still being read.
    @State private var preview: GeometryFieldPreview?
    @State private var fitToken = 0

    init(text: String, source: GeometryFieldSource, initialPreview: GeometryFieldPreview?) {
        self.text = text
        self.source = source
        _preview = State(initialValue: initialPreview)
    }

    private var isDrawable: Bool {
        guard case .drawable = preview else { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await readIfNeeded()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Spacer()

            Button {
                fitToken &+= 1
            } label: {
                Label(String(localized: "Fit to Geometry"), systemImage: "arrow.down.left.and.arrow.up.right")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!isDrawable)
            .accessibilityIdentifier("geometry-map-viewer-fit")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch preview {
        case nil:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Building map"))
        case .drawable(let projection, let caption):
            VStack(spacing: 0) {
                GeometryFieldMapCanvas(
                    projection: projection,
                    projectionToken: 0,
                    fitToken: fitToken,
                    caption: caption,
                    identifier: "geometry-map-viewer-map"
                )
                Divider()
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        case .unavailable(let reason):
            UnavailableStateView {
                Label(String(localized: "Nothing to Draw"), systemImage: "map")
            } description: {
                Text(reason.message)
            }
        }
    }

    /// `.task` runs again whenever the view comes back, so a preview already read is kept.
    private func readIfNeeded() async {
        guard preview == nil else { return }
        let text = text
        let source = source
        let built = await Task.detached(priority: .userInitiated) {
            GeometryFieldPreview.make(text: text, source: source, state: .value(text))
        }.value
        guard !Task.isCancelled else { return }
        preview = built
    }
}
