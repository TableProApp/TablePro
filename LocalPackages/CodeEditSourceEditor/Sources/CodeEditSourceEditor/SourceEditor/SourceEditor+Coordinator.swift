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
        let phase = RepresentableSyncPhase()
        let textSync: TextBindingSync
        @Binding var editorState: SourceEditorState

        private(set) var highlightProviders: [any HighlightProviding]

        /// Held strongly, unlike ``TextViewController/textCoordinators``, which holds them weakly.
        /// SwiftUI keeps this coordinator alive for as long as the editor exists, so the teardown in
        /// ``SourceEditor/dismantleNSViewController(_:coordinator:)`` always has something to
        /// destroy. Going through the weak list instead would make teardown depend on SwiftUI
        /// releasing the view's `@State` after the dismantle rather than before it, which nothing
        /// guarantees.
        let textCoordinators: [any TextViewCoordinator]

        private var cancellables: Set<AnyCancellable> = []

        init(
            text: TextAPI,
            editorState: Binding<SourceEditorState>,
            highlightProviders: [any HighlightProviding]?,
            textCoordinators: [any TextViewCoordinator]
        ) {
            self.textSync = TextBindingSync(text: text, phase: phase)
            self._editorState = editorState
            self.highlightProviders = highlightProviders ?? [TreeSitterClient()]
            self.textCoordinators = textCoordinators
            super.init()
        }

        func setController(_ controller: TextViewController) {
            self.controller = controller
            // swiftlint:disable:next notification_center_detachment
            NotificationCenter.default.removeObserver(self)
            listenToTextViewNotifications(controller: controller)
            listenToCursorNotifications(controller: controller)
            listenToFindNotifications(controller: controller)
            listenToFoldNotifications(controller: controller)
        }

        /// Listen to fold collapse and expand events on the text view controller.
        func listenToFoldNotifications(controller: TextViewController) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textControllerFoldsDidUpdate(_:)),
                name: TextViewController.foldStateDidChangeNotification,
                object: controller
            )
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

        @objc func textViewDidChangeText(_ notification: Notification) {
            guard let textView = notification.object as? TextView else {
                return
            }
            textSync.editorTextDidChange(textView)
        }

        @objc func textControllerCursorsDidUpdate(_ notification: Notification) {
            guard let controller = notification.object as? TextViewController else {
                return
            }
            updateState { $0.cursorPositions = controller.cursorPositions }
        }

        @objc func textControllerFoldsDidUpdate(_ notification: Notification) {
            guard let controller = notification.object as? TextViewController else {
                return
            }
            updateState { $0.collapsedFoldRanges = controller.collapsedFoldRanges }
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
            guard !phase.isApplyingRepresentableValue else { return }
            phase.markEditorChange()
            modifyCallback(&editorState)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
