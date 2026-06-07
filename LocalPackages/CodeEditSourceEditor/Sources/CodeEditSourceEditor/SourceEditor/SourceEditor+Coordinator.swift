//
//  SourceEditor+Coordinator.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/20/24.
//

import AppKit
import SwiftUI
import Combine
import CodeEditTextView

extension SourceEditor {
    @MainActor
    public class Coordinator: NSObject {
        private weak var controller: TextViewController?
        var isUpdatingFromRepresentable: Bool = false
        var isUpdateFromTextView: Bool = false
        var text: TextAPI
        var lastSyncedText: String?
        @Binding var editorState: SourceEditorState

        private(set) var highlightProviders: [any HighlightProviding]

        private var cancellables: Set<AnyCancellable> = []

        init(text: TextAPI, editorState: Binding<SourceEditorState>, highlightProviders: [any HighlightProviding]?) {
            self.text = text
            self._editorState = editorState
            self.highlightProviders = highlightProviders ?? [TreeSitterClient()]
            if case .binding(let binding) = text {
                self.lastSyncedText = binding.wrappedValue
            }
            super.init()
        }

        func setController(_ controller: TextViewController) {
            self.controller = controller
            // swiftlint:disable:next notification_center_detachment
            NotificationCenter.default.removeObserver(self)
            listenToTextViewNotifications(controller: controller)
            listenToCursorNotifications(controller: controller)
            listenToFindNotifications(controller: controller)
        }

        // MARK: - Listeners

        /// Listen to anything related to the text view.
        func listenToTextViewNotifications(controller: TextViewController) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textViewDidChangeText(_:)),
                name: TextView.textDidChangeNotification,
                object: controller.textView
            )

            // Needs to be put on the main runloop or SwiftUI gets mad about updating state during view updates.
            NotificationCenter.default
                .publisher(
                    for: TextViewController.scrollPositionDidUpdateNotification,
                    object: controller
                )
                .receive(on: RunLoop.main)
                .sink { [weak self] notification in
                    self?.textControllerScrollDidChange(notification)
                }
                .store(in: &cancellables)
        }

        /// Listen to the cursor publisher on the text view controller.
        func listenToCursorNotifications(controller: TextViewController) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textControllerCursorsDidUpdate(_:)),
                name: TextViewController.cursorPositionUpdatedNotification,
                object: controller
            )
        }

        /// Listen to all find panel notifications.
        func listenToFindNotifications(controller: TextViewController) {
            NotificationCenter.default
                .publisher(
                    for: FindPanelViewModel.Notifications.textDidChange,
                    object: controller
                )
                .receive(on: RunLoop.main)
                .sink { [weak self] notification in
                    self?.textControllerFindTextDidChange(notification)
                }
                .store(in: &cancellables)

            NotificationCenter.default
                .publisher(
                    for: FindPanelViewModel.Notifications.replaceTextDidChange,
                    object: controller
                )
                .receive(on: RunLoop.main)
                .sink { [weak self] notification in
                    self?.textControllerReplaceTextDidChange(notification)
                }
                .store(in: &cancellables)

            NotificationCenter.default
                .publisher(
                    for: FindPanelViewModel.Notifications.didToggle,
                    object: controller
                )
                .receive(on: RunLoop.main)
                .sink { [weak self] notification in
                    self?.textControllerFindDidToggle(notification)
                }
                .store(in: &cancellables)
        }

        // MARK: - Update Published State

        func updateHighlightProviders(_ highlightProviders: [any HighlightProviding]?) {
            guard let highlightProviders else {
                return // Keep our default `TreeSitterClient` if they're `nil`
            }
            // Otherwise, we can replace the stored providers.
            self.highlightProviders = highlightProviders
        }

        private var textBindingTask: Task<Void, Never>?

        @objc func textViewDidChangeText(_ notification: Notification) {
            guard let textView = notification.object as? TextView else {
                return
            }
            guard !isUpdatingFromRepresentable else { return }
            guard case .binding(let binding) = text else { return }

            // For large documents, debounce the binding writeback to avoid
            // copying megabytes of text into SwiftUI on every keystroke.
            let docLength = textView.textStorage.length
            // Set flag immediately so SwiftUI's updateNSViewController knows
            // the text view is the source of truth during the debounce window.
            isUpdateFromTextView = true
            if docLength > 500_000 {
                textBindingTask?.cancel()
                textBindingTask = Task { @MainActor [weak self, weak textView] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, let self, let textView else { return }
                    guard case .binding(let currentBinding) = self.text else { return }
                    let newText = textView.string
                    self.lastSyncedText = newText
                    currentBinding.wrappedValue = newText
                }
            } else {
                let newText = textView.string
                lastSyncedText = newText
                binding.wrappedValue = newText
            }
        }

        /// Pushes an external binding change down into the text view. The text view's
        /// content wins while one of its own edits is still in flight: `isUpdateFromTextView`
        /// is set the moment the text view mutates, before SwiftUI re-renders, so a render
        /// that still carries a stale binding snapshot is skipped entirely and user typing
        /// is never clobbered by a stale binding.
        ///
        /// Uses `setText` rather than `replaceCharacters` on purpose: `replaceCharacters`
        /// is the user-edit path. It is gated on `isEditable`, runs mutation filters, and
        /// fires suggestion triggers, none of which should happen for a programmatic
        /// whole-document replacement. `setText` clearing the undo stack matches the
        /// new-document semantics of that replacement.
        func syncBindingText(_ newValue: String, controller: TextViewController) {
            guard !isUpdateFromTextView else { return }
            guard newValue != lastSyncedText else { return }
            textBindingTask?.cancel()
            isUpdatingFromRepresentable = true
            controller.textView.setText(newValue)
            isUpdatingFromRepresentable = false
            lastSyncedText = newValue
        }

        @objc func textControllerCursorsDidUpdate(_ notification: Notification) {
            guard let controller = notification.object as? TextViewController else {
                return
            }
            updateState { $0.cursorPositions = controller.cursorPositions }
        }

        func textControllerScrollDidChange(_ notification: Notification) {
            guard let controller = notification.object as? TextViewController else {
                return
            }
            let currentPosition = controller.scrollView.contentView.bounds.origin
            if editorState.scrollPosition != currentPosition {
                updateState { $0.scrollPosition = currentPosition }
            }
        }

        func textControllerFindTextDidChange(_ notification: Notification) {
            guard let controller = notification.object as? TextViewController,
                  let findModel = controller.findViewController?.viewModel else {
                return
            }
            updateState { $0.findText = findModel.findText }
        }

        func textControllerReplaceTextDidChange(_ notification: Notification) {
            guard let controller = notification.object as? TextViewController,
                  let findModel = controller.findViewController?.viewModel else {
                return
            }
            updateState { $0.replaceText = findModel.replaceText }
        }

        func textControllerFindDidToggle(_ notification: Notification) {
            guard let controller = notification.object as? TextViewController,
                  let findModel = controller.findViewController?.viewModel else {
                return
            }
            updateState { $0.findPanelVisible = findModel.isShowingFindPanel }
        }

        private func updateState(_ modifyCallback: (inout SourceEditorState) -> Void) {
            guard !isUpdatingFromRepresentable else { return }
            self.isUpdateFromTextView = true
            modifyCallback(&editorState)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
