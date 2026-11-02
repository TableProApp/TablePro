//
//  GeometryFieldView.swift
//  TablePro
//

import Combine
import SwiftUI
import TableProTheme

// A geometry value drawn as a map, with the field's own editor one segment away.
internal struct GeometryFieldView: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    let context: FieldEditorContext
    let descriptor: GeometryFieldDescriptor
    var onPopOut: ((String) -> Void)?
    var isExpanded = false
    // Told whether Tab can stop here without Full Keyboard Access; a map takes no focus.
    var onTabStopChange: ((Bool) -> Void)?

    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(PreferenceKeys.rowInspectorGeometryFieldMode.name, store: AppStorageEnvironment.shared.defaults)
    private var storedMode = Mode.map.rawValue

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
        // On a bare container the row's accessibility value lands on the picker and the caption.
        .accessibilityElement(children: .contain)
        .onAppear { onTabStopChange?(mode == .text) }
        // No reset on disappear: the lazy list unmounts off-screen rows, and Tab would then stop on a map.
        .onChange(of: mode) { onTabStopChange?($0 == .text) }
        // Reruns when a read starts or ends, so whichever preview comes first latches the mode.
        .task(id: resolution.pending) {
            guard let pending = resolution.pending else {
                latch.offer(preferred: preferredMode, preview: resolution.preview)
                return
            }
            guard let loaded = await previews.load(pending, source: descriptor.source) else { return }
            latch.offer(preferred: preferredMode, preview: loaded)
        }
    }

    // Text mode reads nothing: the value is parsed only while a map is, or may be, on screen.
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
            .viewSwitcherStyle()
            .labelsHidden()
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

    // Only the picker latches and stores the mode, so a value turning drawable as it is typed stays on Text.
    private func modeSelection(shown mode: Mode) -> Binding<Mode> {
        Binding(
            get: { mode },
            set: { chosen in
                latch.choose(chosen)
                storedMode = chosen.rawValue
            }
        )
    }

    // No window edits bytes: the text window would write them back as text.
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

    // The map window gets the text alone and would call NULL or mixed values unreadable, so only a drawable value opens it.
    static func canOpenWindow(in mode: Mode, preview: GeometryFieldPreview?) -> Bool {
        switch mode {
        case .map: return isDrawable(preview)
        case .text: return true
        }
    }

    // MARK: - Panes

    // The toolbar's pop-out serves both segments; this kind opts out of the row's value font, so the pane sets it.
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
                column: context.columnName,
                defaultHeight: ResizableFieldMetrics.defaultGeometryHeight,
                range: ResizableFieldMetrics.geometryHeightRange,
                expandedHeight: isExpanded ? ResizableFieldMetrics.expandedHeight : nil
            ) {
                mapContent(preview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .geometryMapWell()
            }
            if case .drawable(_, let caption) = preview {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Dropped while disabled, which is how the inspector hides it behind the JSON rendering: a mounted map holds about 45 MB.
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

        // Nil while the first read of a large value is still running.
        static func opening(preferred: Mode, preview: GeometryFieldPreview?) -> Mode? {
            guard preferred == .map else { return .text }
            switch preview {
            case .drawable: return .map
            case .unavailable: return .text
            case nil: return nil
            }
        }
    }

    // Decided once per view: following the text would swap the editor from under the caret once a typed value draws.
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

// Once per text, not per body pass, since every keystroke redraws every field. Unpublished, so filling it redraws nothing.
@MainActor
internal final class GeometryFieldPreviewStore: ObservableObject {
    internal struct Request: Equatable, Sendable {
        let text: String
        let state: FieldValueState
    }

    internal struct Resolution {
        // While `pending` is set this is the previous value's preview, so the map stays up during a re-read.
        let preview: GeometryFieldPreview?
        let pending: Request?
    }

    internal typealias Reader = @Sendable (Request, GeometryFieldSource) -> GeometryFieldPreview

    internal private(set) var preview: GeometryFieldPreview?
    // Moves with the shapes, so the canvas can tell new ones from the ones it already drew.
    internal private(set) var token = 0
    private var loaded: Request?
    private var pending: Request?
    // A parse runs to the end, so a pane re-added mid-read joins it instead of starting a second one.
    private var inFlight: (request: Request, task: Task<GeometryFieldPreview, Never>)?
    private let reader: Reader

    internal init(reader: @escaping Reader = { request, source in
        GeometryFieldPreview.make(text: request.text, source: source, state: request.state)
    }) {
        self.reader = reader
    }

    internal func resolve(_ request: Request, source: GeometryFieldSource) -> Resolution {
        if request == loaded { return Resolution(preview: preview, pending: nil) }
        if request == pending { return Resolution(preview: preview, pending: request) }
        guard GeometryFieldPreview.readsSynchronously(request.text) else {
            pending = request
            return Resolution(preview: preview, pending: request)
        }
        commit(reader(request, source), for: request)
        return Resolution(preview: preview, pending: nil)
    }

    // Nil when the value moved on during the read. A finished read commits even when its caller was cancelled.
    internal func load(_ request: Request, source: GeometryFieldSource) async -> GeometryFieldPreview? {
        if request == loaded { return preview }
        let task: Task<GeometryFieldPreview, Never>
        if let inFlight, inFlight.request == request {
            task = inFlight.task
        } else {
            let reader = reader
            task = Task.detached(priority: .userInitiated) { reader(request, source) }
            inFlight = (request, task)
        }
        let made = await task.value
        if inFlight?.request == request { inFlight = nil }
        if request == loaded { return preview }
        guard request == pending else { return nil }
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

internal extension View {
    // Shows while the map builds, or for a value with nothing to draw.
    func geometryMapWell() -> some View {
        themeBackground(.editorBackground, native: Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
