//
//  InlineAssistantPresenter.swift
//  TablePro
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import os

@MainActor
final class InlineAssistantPresenter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "InlineAssistantPresenter")

    private weak var controller: TextViewController?
    private var session: InlineAssistantSession?
    private var overlay: InlineAssistantOverlayController?
    private var anchorRange = NSRange(location: 0, length: 0)
    private var schemaProvider: (() -> SQLSchemaProvider?)?
    private var databaseTypeResolver: (() -> DatabaseType?)?

    var isActive: Bool { overlay != nil }

    func install(
        controller: TextViewController,
        schemaProvider: @escaping () -> SQLSchemaProvider?,
        databaseType: @escaping () -> DatabaseType?
    ) {
        self.controller = controller
        self.schemaProvider = schemaProvider
        self.databaseTypeResolver = databaseType
    }

    func uninstall() {
        dismiss()
        controller = nil
        schemaProvider = nil
        databaseTypeResolver = nil
    }

    func presentForSelection() {
        guard !isActive else { return }
        guard let controller, let textView = controller.textView else { return }

        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0 else {
            NSSound.beep()
            return
        }

        let nsString = textView.string as NSString
        let selectedText = nsString.substring(with: selectedRange)
        let fullQuery = textView.string

        let session = InlineAssistantSession(
            originalText: selectedText,
            fullQuery: fullQuery,
            databaseType: databaseTypeResolver?(),
            schemaProvider: schemaProvider?()
        )
        self.session = session
        self.anchorRange = selectedRange

        let overlay = InlineAssistantOverlayController()
        self.overlay = overlay

        let view = makeView(for: session)
        overlay.present(view: view, anchorRange: selectedRange, in: textView)
    }

    func dismiss() {
        session?.teardown()
        session = nil
        overlay?.dismiss()
        overlay = nil
    }

    private func makeView(for session: InlineAssistantSession) -> InlineAssistantPromptView {
        InlineAssistantPromptView(
            session: session,
            onSubmit: { [weak self] in self?.handleSubmit() },
            onCancel: { [weak self] in self?.handleCancel() },
            onAccept: { [weak self] in self?.handleAccept() },
            onReject: { [weak self] in self?.handleReject() }
        )
    }

    private func handleSubmit() {
        session?.start()
    }

    private func handleCancel() {
        if let session, session.isStreaming {
            session.cancel()
            return
        }
        dismiss()
    }

    private func handleAccept() {
        guard let session, session.hasResponse else { return }
        guard let textView = controller?.textView else { return }

        let storage = textView.string as NSString
        guard anchorRange.upperBound <= storage.length else {
            Self.logger.warning("Inline assistant: anchor range out of bounds, aborting accept")
            dismiss()
            return
        }
        let replacement = session.proposedText
        textView.replaceCharacters(in: anchorRange, with: replacement)
        let newRange = NSRange(location: anchorRange.location, length: (replacement as NSString).length)
        textView.selectionManager.setSelectedRange(newRange)
        dismiss()
    }

    private func handleReject() {
        dismiss()
    }
}
