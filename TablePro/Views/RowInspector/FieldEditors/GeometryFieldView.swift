//
//  GeometryFieldView.swift
//  TablePro
//

import Combine
import SwiftUI

/// A field whose value is a geometry: a map of that value, with the editor the field would
/// otherwise get one segment away.
internal struct GeometryFieldView: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    let context: FieldEditorContext
    let descriptor: GeometryFieldDescriptor
    var onPopOut: ((String) -> Void)?
    var isExpanded = false
    /// Told whether Tab can stop here without Full Keyboard Access. A map takes no focus.
    var onTabStopChange: ((Bool) -> Void)?

    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(PreferenceKeys.rowInspectorGeometryFieldMode.name, store: AppStorageEnvironment.shared.defaults)
    private var storedMode = Mode.map.rawValue
    @AppStorage(PreferenceKeys.rowInspectorGeometryFieldHeight.name, store: AppStorageEnvironment.shared.defaults)
    private var mapHeight = ResizableFieldMetrics.defaultGeometryHeight

    @StateObject private var previews = GeometryFieldPreviewStore()
    @State private var latch = ModeLatch()
    @State private var fitRequests = 0

    private var preferredMode: Mode {
        Mode(rawValue: storedMode) ?? .map
    }

    var body: some View {
        let resolution = resolvePreview()
        let mode = latch.shown(preferred: preferredMode, preview: resolution.preview)
        VStack(alignment: .leading, spacing: 4) {
            toolbar(mode: mode, preview: resolution.preview)
            switch mode {
            case .text:
                textPane
            case .map:
                mapPane(resolution.preview)
            }
        }
        /// The row puts the field's text on its editor as an accessibility value. On a bare
        /// container that lands on the picker and the caption, in place of the selected segment.
        .accessibilityElement(children: .contain)
        .onAppear { onTabStopChange?(mode == .text) }
        /// No reset on disappear: a lazy list unmounts a row scrolled out of view while the field is
        /// still in the list, and Tab would then stop on a map with nothing to focus.
        .onChange(of: mode) { onTabStopChange?($0 == .text) }
        /// Runs again when a read starts or ends, so the mode is latched by whichever preview
        /// comes first: the one read during this pass, or the large one read here.
        .task(id: resolution.pending) {
            guard let pending = resolution.pending else {
                latch.offer(preferred: preferredMode, preview: resolution.preview)
                return
            }
            guard let loaded = await previews.load(pending, source: descriptor.source) else { return }
            latch.offer(preferred: preferredMode, preview: loaded)
        }
    }

    /// Text mode reads nothing: the value is only parsed while a map is, or may be, on screen.
    private func resolvePreview() -> GeometryFieldPreviewStore.Resolution {
        guard latch.needsPreview(preferred: preferredMode) else {
            return GeometryFieldPreviewStore.Resolution(preview: nil, pending: nil)
        }
        let request = GeometryFieldPreviewStore.Request(
            text: context.value.wrappedValue,
            state: context.valueState
        )
        return previews.resolve(request, source: descriptor.source)
    }

    // MARK: - Toolbar

    private func toolbar(mode: Mode, preview: GeometryFieldPreview?) -> some View {
        HStack(spacing: 8) {
            Picker(String(localized: "View Mode"), selection: modeSelection(shown: mode)) {
                Text(String(localized: "Text")).tag(Mode.text)
                Text(String(localized: "Map")).tag(Mode.map)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("inspector-geometry-mode")

            Spacer(minLength: 4)

            if mode == .map {
                Button(String(localized: "Fit to Geometry"), systemImage: "viewfinder") {
                    fitRequests &+= 1
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!Self.isDrawable(preview))
                .help(String(localized: "Fit to Geometry"))
                .accessibilityLabel(String(localized: "Fit to Geometry"))
            }
            if offersWindow(in: mode) {
                Button(String(localized: "Open in Window"), systemImage: "arrow.up.forward.app") {
                    openInWindow(from: mode)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!Self.canOpenWindow(in: mode, preview: preview))
                .help(String(localized: "Open in Window"))
                .accessibilityLabel(String(localized: "Open in Window"))
            }
        }
    }

    /// Only the picker latches a mode and only the picker writes the preference, so a value that
    /// becomes drawable while it is typed never moves the field off Text.
    private func modeSelection(shown mode: Mode) -> Binding<Mode> {
        Binding(
            get: { mode },
            set: { chosen in
                latch.choose(chosen)
                storedMode = chosen.rawValue
            }
        )
    }

    /// No window edits bytes: the text window would write the bytes back as text.
    private func offersWindow(in mode: Mode) -> Bool {
        switch mode {
        case .map: return true
        case .text: return onPopOut != nil && descriptor.textEditor != .hex
        }
    }

    private func openInWindow(from mode: Mode) {
        let text = context.value.wrappedValue
        switch mode {
        case .map:
            GeometryMapWindowController.open(
                text: text,
                source: descriptor.source,
                columnName: context.columnName
            )
        case .text:
            onPopOut?(text)
        }
    }

    private static func isDrawable(_ preview: GeometryFieldPreview?) -> Bool {
        if case .drawable = preview { return true }
        return false
    }

    /// The map window is handed the text alone, so it would call a NULL field or a selection of
    /// several values unreadable. It opens for a value that draws and for nothing else.
    static func canOpenWindow(in mode: Mode, preview: GeometryFieldPreview?) -> Bool {
        switch mode {
        case .map: return isDrawable(preview)
        case .text: return true
        }
    }

    // MARK: - Panes

    /// The embedded editors carry no pop-out button of their own: the toolbar's one button serves
    /// both segments. This kind opts out of the row's value font, so the pane names it.
    private var textPane: some View {
        Group {
            switch descriptor.textEditor {
            case .multiLine:
                MultiLineEditorView(context: context, onPopOut: nil, isExpanded: isExpanded)
            case .json:
                JsonEditorView(context: context, onPopOut: nil, isExpanded: isExpanded)
            case .hex:
                BlobHexEditorView(context: context)
            }
        }
        .font(themeEngine.valueFontSwiftUI)
    }

    private func mapPane(_ preview: GeometryFieldPreview?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ResizableEditorContainer(
                height: $mapHeight,
                range: ResizableFieldMetrics.geometryHeightRange,
                expandedHeight: isExpanded ? ResizableFieldMetrics.expandedHeight : nil
            ) {
                mapContent(preview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            }
            if case .drawable(_, let caption) = preview {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The canvas is dropped while the list is disabled, which is how the inspector hides it behind
    /// its JSON rendering: a mounted map view holds about 45 MB whether or not it is on screen.
    @ViewBuilder
    private func mapContent(_ preview: GeometryFieldPreview?) -> some View {
        switch preview {
        case .drawable(let projection, let caption):
            if isEnabled {
                GeometryFieldMapCanvas(
                    projection: projection,
                    projectionToken: previews.token,
                    fitToken: fitRequests,
                    caption: caption
                )
            }
        case .unavailable(let reason):
            Text(reason.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .help(reason.message)
        case nil:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Building map"))
        }
    }
}

// MARK: - Mode

internal extension GeometryFieldView {
    enum Mode: String, Hashable, Sendable {
        case text
        case map

        /// Nil while the first read of a large value is still running: nothing has decided yet.
        static func opening(preferred: Mode, preview: GeometryFieldPreview?) -> Mode? {
            guard preferred == .map else { return .text }
            switch preview {
            case .drawable: return .map
            case .unavailable: return .text
            case nil: return nil
            }
        }
    }

    /// The mode a field opens on is decided once per view. Following the text instead would swap
    /// the editor out from under the caret the moment a typed value became drawable.
    struct ModeLatch: Equatable {
        private(set) var mode: Mode?

        mutating func offer(preferred: Mode, preview: GeometryFieldPreview?) {
            guard mode == nil else { return }
            mode = Mode.opening(preferred: preferred, preview: preview)
        }

        mutating func choose(_ chosen: Mode) {
            mode = chosen
        }

        func shown(preferred: Mode, preview: GeometryFieldPreview?) -> Mode {
            mode ?? Mode.opening(preferred: preferred, preview: preview) ?? .map
        }

        func needsPreview(preferred: Mode) -> Bool {
            (mode ?? preferred) == .map
        }
    }
}

// MARK: - Preview store

/// Reads a value once per text rather than once per body pass: the list redraws every field on
/// each keystroke in any of them. Not published, so filling it during a pass redraws nothing.
@MainActor
internal final class GeometryFieldPreviewStore: ObservableObject {
    internal struct Request: Equatable, Sendable {
        let text: String
        let state: FieldValueState
    }

    internal struct Resolution {
        /// The newest preview there is. While `pending` is set it is the previous value's, so the
        /// map stays up during a re-read.
        let preview: GeometryFieldPreview?
        let pending: Request?
    }

    internal private(set) var preview: GeometryFieldPreview?
    /// Moves with the shapes, so the canvas can tell new ones from the ones it already drew.
    internal private(set) var token = 0
    private var loaded: Request?
    private var pending: Request?

    internal func resolve(_ request: Request, source: GeometryFieldSource) -> Resolution {
        if request == loaded { return Resolution(preview: preview, pending: nil) }
        if request == pending { return Resolution(preview: preview, pending: request) }
        guard GeometryFieldPreview.readsSynchronously(request.text) else {
            pending = request
            return Resolution(preview: preview, pending: request)
        }
        commit(GeometryFieldPreview.make(text: request.text, source: source, state: request.state), for: request)
        return Resolution(preview: preview, pending: nil)
    }

    /// Nil when the value moved on while this one was being read.
    internal func load(_ request: Request, source: GeometryFieldSource) async -> GeometryFieldPreview? {
        /// A re-added pane restarts its tasks with an unchanged id.
        if request == loaded { return preview }
        let made = await Task.detached(priority: .userInitiated) {
            GeometryFieldPreview.make(text: request.text, source: source, state: request.state)
        }.value
        guard !Task.isCancelled, request == pending else { return nil }
        objectWillChange.send()
        commit(made, for: request)
        return made
    }

    private func commit(_ made: GeometryFieldPreview, for request: Request) {
        loaded = request
        pending = nil
        preview = made
        token &+= 1
    }
}
