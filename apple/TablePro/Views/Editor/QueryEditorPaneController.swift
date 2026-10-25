//
//  QueryEditorPaneController.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProEditorKit

/// What the query tab's editor pane shows: the header above the editor, and the editor's input.
struct QueryEditorPaneInput {
    /// The banner, the command bar and the parameter panel, given the Vim mode to show or nil.
    var header: (VimMode?) -> AnyView
    var editor: SQLEditorInput
}

@MainActor
final class QueryEditorPaneModel: ObservableObject {
    @Published var vimMode: VimMode = .normal
}

struct QueryEditorHeader: View {
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    @ObservedObject var model: QueryEditorPaneModel
    let content: (VimMode?) -> AnyView

    var body: some View {
        content(settingsManager.editor.keyBindings == .vim ? model.vimMode : nil)
    }
}

/// The SQL editor under its command bar. The editor takes whatever height the header leaves, with no minimum of its
/// own: the pane bottoms out at the query split's top minimum, and an editor that also insisted on one overflowed it.
@MainActor
final class QueryEditorPaneController: NSViewController {
    let editor: SQLEditorController
    private let model = QueryEditorPaneModel()
    let header: NSHostingView<QueryEditorHeader>

    init(input: QueryEditorPaneInput) {
        editor = SQLEditorController(input: input.editor)
        header = NSHostingView(rootView: QueryEditorHeader(model: model, content: input.header))
        super.init(nibName: nil, bundle: nil)
        editor.onVimModeChange = { [weak self] mode in self?.model.vimMode = mode }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        header.sizingOptions = [.intrinsicContentSize]
        header.translatesAutoresizingMaskIntoConstraints = false
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.setContentHuggingPriority(.required, for: .vertical)
        root.addSubview(header)

        let textController = editor.textViewController
        addChild(textController)
        let editorView = textController.view
        editorView.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 14.0, *) {
            editorView.clipsToBounds = true
        }
        root.addSubview(editorView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editorView.topAnchor.constraint(equalTo: header.bottomAnchor),
            editorView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editorView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    func apply(_ input: QueryEditorPaneInput) {
        header.rootView = QueryEditorHeader(model: model, content: input.header)
        editor.apply(input.editor)
    }

    func teardown() {
        editor.teardown()
    }
}
