//
//  SourceEditor.swift
//  CodeEditSourceEditor
//
//  Created by Lukas Pistrol on 24.05.22.
//

import AppKit
import SwiftUI
import CodeEditTextView
import CodeEditLanguages

/// A SwiftUI View that provides source editing functionality.
public struct SourceEditor: NSViewControllerRepresentable {
    enum TextAPI {
        case binding(Binding<String>)
        case storage(NSTextStorage)
    }

    /// Initializes a new source editor
    /// - Parameters:
    ///   - text: The text content
    ///   - language: The language for syntax highlighting
    ///   - configuration: A configuration object, determining appearance, layout, behaviors  and more.
    ///                    See ``SourceEditorConfiguration``.
    ///   - cursorPositions: The cursor's position in the editor, measured in `(lineNum, columnNum)`
    ///   - highlightProviders: A set of classes you provide to perform syntax highlighting. Leave this as `nil` to use
    ///                         the default `TreeSitterClient` highlighter.
    ///   - foldProvider: A class you provide to find fold regions in the document. Leave this as `nil` to use the
    ///                    default indentation-based provider.
    ///   - undoManager: The undo manager for the text view. Defaults to `nil`, which will create a new CEUndoManager
    ///   - coordinators: Any text coordinators for the view to use. See ``TextViewCoordinator`` for more information.
    public init(
        _ text: Binding<String>,
        language: CodeLanguage,
        configuration: SourceEditorConfiguration,
        state: Binding<SourceEditorState>,
        highlightProviders: [any HighlightProviding]? = nil,
        foldProvider: LineFoldProvider? = nil,
        undoManager: CEUndoManager? = nil,
        coordinators: [any TextViewCoordinator] = [],
        completionDelegate: CodeSuggestionDelegate? = nil,
        jumpToDefinitionDelegate: JumpToDefinitionDelegate? = nil
    ) {
        self.text = .binding(text)
        self.language = language
        self.configuration = configuration
        self._state = state
        self.highlightProviders = highlightProviders
        self.foldProvider = foldProvider
        self.undoManager = undoManager
        self.coordinators = coordinators
        self.completionDelegate = completionDelegate
        self.jumpToDefinitionDelegate = jumpToDefinitionDelegate
    }

    /// Initializes a new source editor
    /// - Parameters:
    ///   - text: The text content
    ///   - language: The language for syntax highlighting
    ///   - configuration: A configuration object, determining appearance, layout, behaviors  and more.
    ///                    See ``SourceEditorConfiguration``.
    ///   - cursorPositions: The cursor's position in the editor, measured in `(lineNum, columnNum)`
    ///   - highlightProviders: A set of classes you provide to perform syntax highlighting. Leave this as `nil` to use
    ///                         the default `TreeSitterClient` highlighter.
    ///   - foldProvider: A class you provide to find fold regions in the document. Leave this as `nil` to use the
    ///                    default indentation-based provider.
    ///   - undoManager: The undo manager for the text view. Defaults to `nil`, which will create a new CEUndoManager
    ///   - coordinators: Any text coordinators for the view to use. See ``TextViewCoordinator`` for more information.
    public init(
        _ text: NSTextStorage,
        language: CodeLanguage,
        configuration: SourceEditorConfiguration,
        state: Binding<SourceEditorState>,
        highlightProviders: [any HighlightProviding]? = nil,
        foldProvider: LineFoldProvider? = nil,
        undoManager: CEUndoManager? = nil,
        coordinators: [any TextViewCoordinator] = [],
        completionDelegate: CodeSuggestionDelegate? = nil,
        jumpToDefinitionDelegate: JumpToDefinitionDelegate? = nil
    ) {
        self.text = .storage(text)
        self.language = language
        self.configuration = configuration
        self._state = state
        self.highlightProviders = highlightProviders
        self.foldProvider = foldProvider
        self.undoManager = undoManager
        self.coordinators = coordinators
        self.completionDelegate = completionDelegate
        self.jumpToDefinitionDelegate = jumpToDefinitionDelegate
    }

    var text: TextAPI
    var language: CodeLanguage
    var configuration: SourceEditorConfiguration
    @Binding var state: SourceEditorState
    var highlightProviders: [any HighlightProviding]?
    var foldProvider: LineFoldProvider?
    var undoManager: CEUndoManager?
    var coordinators: [any TextViewCoordinator]
    var completionDelegate: CodeSuggestionDelegate?
    var jumpToDefinitionDelegate: JumpToDefinitionDelegate?

    public typealias NSViewControllerType = TextViewController

    public func makeNSViewController(context: Context) -> TextViewController {
        let controller = TextViewController(
            string: "",
            language: language,
            configuration: configuration,
            cursorPositions: state.cursorPositions ?? [],
            highlightProviders: context.coordinator.highlightProviders,
            foldProvider: foldProvider,
            undoManager: undoManager,
            coordinators: coordinators,
            completionDelegate: completionDelegate,
            jumpToDefinitionDelegate: jumpToDefinitionDelegate
        )
        switch text {
        case .binding(let binding):
            controller.textView.setText(binding.wrappedValue)
        case .storage(let textStorage):
            controller.textView.setTextStorage(textStorage)
        }
        if controller.textView == nil {
            controller.loadView()
        }
        if !(state.cursorPositions?.isEmpty ?? true) {
            controller.setCursorPositions(state.cursorPositions ?? [])
        }

        context.coordinator.setController(controller)
        return controller
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            text: text,
            editorState: $state,
            highlightProviders: highlightProviders,
            textCoordinators: coordinators
        )
    }

    /// The editor's terminal signal: SwiftUI calls this only when the representable is removed for
    /// good, never when its host view merely leaves the window.
    ///
    /// Appearance is not lifetime. A host that keeps a controller alive while unparenting its view
    /// fires `onDisappear` and then `onAppear` again on the same identity, so a teardown driven from
    /// `onDisappear` runs on a live editor and cannot be undone. `TextViewController.deinit` is not
    /// a usable substitute either, because it is not guaranteed to run promptly. The destroy goes
    /// through ``Coordinator/textCoordinators``, and `releaseHeavyState` then empties the
    /// controller's weak list so `deinit` cannot destroy the same coordinators twice.
    public static func dismantleNSViewController(_ controller: TextViewController, coordinator: Coordinator) {
        coordinator.textCoordinators.forEach { $0.destroy() }
        controller.releaseHeavyState()
    }

    public func updateNSViewController(_ controller: TextViewController, context: Context) {
        controller.completionDelegate = completionDelegate
        controller.jumpToDefinitionDelegate = jumpToDefinitionDelegate

        context.coordinator.updateHighlightProviders(highlightProviders)

        context.coordinator.textSync.text = text
        if case .binding(let binding) = text {
            context.coordinator.textSync.applyRepresentableText(binding.wrappedValue, controller: controller)
        }

        if !context.coordinator.phase.consumePendingEditorChange() {
            context.coordinator.phase.applyRepresentableValue {
                updateControllerWithState(state, controller: controller)
            }
        }

        // Do manual diffing to reduce the amount of reloads.
        // This helps a lot in view performance, as it otherwise gets triggered on each environment change.
        guard !paramsAreEqual(controller: controller, coordinator: context.coordinator) else {
            return
        }

        if controller.language != language {
            controller.language = language
        }
        controller.configuration = configuration
        updateHighlighting(controller, coordinator: context.coordinator)

        controller.reloadUI()
        return
    }

    private func updateControllerWithState(_ state: SourceEditorState, controller: TextViewController) {
        if let cursorPositions = state.cursorPositions, cursorPositions != controller.cursorPositions {
            controller.setCursorPositions(cursorPositions)
        }

        let scrollView = controller.scrollView
        if let scrollPosition = state.scrollPosition, scrollPosition != scrollView?.contentView.bounds.origin {
            controller.scrollView.scroll(controller.scrollView.contentView, to: scrollPosition)
            controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
            controller.gutterView.needsDisplay = true
            NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: controller.textView)
        }

        if let findText = state.findText, findText != controller.findViewController?.viewModel.findText {
            controller.findViewController?.viewModel.findText = findText
        }

        if let replaceText = state.replaceText, replaceText != controller.findViewController?.viewModel.replaceText {
            controller.findViewController?.viewModel.replaceText = replaceText
        }

        if let findPanelVisible = state.findPanelVisible,
           let findController = controller.findViewController,
           findController.viewModel.isShowingFindPanel != findPanelVisible {
            // Needs to be on the next runloop, not many great ways to do this besides a dispatch...
            DispatchQueue.main.async {
                if findPanelVisible {
                    findController.showFindPanel()
                } else {
                    findController.hideFindPanel()
                }
            }
        }
    }

    private func updateHighlighting(_ controller: TextViewController, coordinator: Coordinator) {
        if !areHighlightProvidersEqual(controller: controller, coordinator: coordinator) {
            controller.setHighlightProviders(coordinator.highlightProviders)
        }
    }

    /// Checks if the controller needs updating.
    /// - Parameter controller: The controller to check.
    /// - Returns: True, if the controller's parameters should be updated.
    func paramsAreEqual(controller: NSViewControllerType, coordinator: Coordinator) -> Bool {
        controller.language.id == language.id &&
        controller.configuration == configuration &&
        areHighlightProvidersEqual(controller: controller, coordinator: coordinator)
    }

    private func areHighlightProvidersEqual(controller: TextViewController, coordinator: Coordinator) -> Bool {
        controller.highlightProviders.map { ObjectIdentifier($0) }
        == coordinator.highlightProviders.map { ObjectIdentifier($0) }
    }
}
