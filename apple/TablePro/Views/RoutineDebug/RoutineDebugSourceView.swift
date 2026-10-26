//
//  RoutineDebugSourceView.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProEditorKit
import TableProGrammars

// The editor owns the ribbon's drawing and the host owns its contents, so the two meet only through this object.
@MainActor
internal final class RoutineDebugSourceBridge: TextViewCoordinator {
    private weak var controller: TextViewController?
    var onToggleBreakpoint: ((Int) -> Void)?
    var onCursorLine: ((Int?) -> Void)?
    private var breakpointLines: Set<Int> = []
    private var executionLine: Int?

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        controller.onBreakpointToggle = { [weak self] line in
            self?.onToggleBreakpoint?(line)
        }
        apply()
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        let line = newPositions.first?.start.line
        onCursorLine?(line.flatMap { $0 > 0 ? $0 : nil })
    }

    func show(breakpoints: Set<Int>, executionLine: Int?) {
        breakpointLines = breakpoints
        self.executionLine = executionLine
        apply()
    }

    func destroy() {
        controller?.onBreakpointToggle = nil
        controller = nil
    }

    private func apply() {
        guard let controller else { return }
        if controller.breakpointLines != breakpointLines {
            controller.breakpointLines = breakpointLines
        }
        if controller.executionLine != executionLine {
            controller.executionLine = executionLine
        }
    }
}

// Read-only on purpose: breakpoint and stop lines index the text the session returned, so an edit would misplace them.
internal struct RoutineDebugSourceView: View {
    @ObservedObject var controller: RoutineDebugController
    let databaseType: DatabaseType

    @State private var text = ""
    @State private var editorState = SourceEditorState()
    @State private var bridge = RoutineDebugSourceBridge()
    @State private var configuration = Self.makeConfiguration()

    var body: some View {
        Group {
            if controller.displayedUnit == nil {
                placeholder
            } else {
                SourceEditor(
                    $text,
                    language: PluginManager.shared.editorLanguage(for: databaseType).treeSitterLanguage,
                    configuration: configuration,
                    state: $editorState,
                    coordinators: [bridge]
                )
            }
        }
        .onAppear(perform: syncAll)
        .onChange(of: controller.displayedSource) { source in
            text = source
            syncMarkers()
        }
        .onChange(of: controller.displayedBreakpointLines) { _ in syncMarkers() }
        .onChange(of: controller.executionLine) { _ in syncMarkers() }
        .onReceive(AppEvents.shared.themeChanged) { _ in
            configuration = Self.makeConfiguration()
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if controller.state.isTerminal {
            Color.clear
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func syncAll() {
        let controller = controller
        bridge.onToggleBreakpoint = { [weak controller] line in
            controller?.toggleBreakpoint(atLine: line)
        }
        bridge.onCursorLine = { [weak controller] line in
            controller?.cursorLine = line
        }
        text = controller.displayedSource
        syncMarkers()
    }

    private func syncMarkers() {
        bridge.show(breakpoints: controller.displayedBreakpointLines, executionLine: controller.executionLine)
    }

    private static func makeConfiguration() -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: ThemeEngine.shared.makeEditorTheme(),
                font: ThemeEngine.shared.editorFonts.font,
                wrapLines: false
            ),
            behavior: .init(isEditable: false),
            layout: .init(contentInsets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)),
            peripherals: .init(
                showGutter: true,
                showLineNumbers: true,
                showFoldingRibbon: false,
                showSpecialCharacters: false,
                showBreakpoints: true
            )
        )
    }
}
