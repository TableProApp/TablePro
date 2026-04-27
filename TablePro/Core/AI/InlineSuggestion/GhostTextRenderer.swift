//
//  GhostTextRenderer.swift
//  TablePro
//

@preconcurrency import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import os

@MainActor
final class GhostTextRenderer {
    private static let logger = Logger(subsystem: "com.TablePro", category: "GhostTextRenderer")

    private weak var controller: TextViewController?
    private var ghostLayer: CATextLayer?
    private var currentText: String?
    private var currentOffset: Int = 0
    private let _scrollObserver = OSAllocatedUnfairLock<Any?>(initialState: nil)

    deinit {
        if let observer = _scrollObserver.withLock({ $0 }) { NotificationCenter.default.removeObserver(observer) }
    }

    func install(controller: TextViewController) {
        self.controller = controller
    }

    func show(_ text: String, at offset: Int) {
        guard let textView = controller?.textView else { return }
        guard let rect = textView.layoutManager.rectForOffset(offset) else { return }

        ghostLayer?.removeFromSuperlayer()
        ghostLayer = nil

        currentText = text
        currentOffset = offset

        let layer = CATextLayer()
        layer.contentsScale = textView.window?.backingScaleFactor ?? 2.0
        layer.allowsFontSubpixelQuantization = true

        let font = ThemeEngine.shared.editorFonts.font
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        layer.string = NSAttributedString(string: text, attributes: attrs)

        let maxWidth = max(textView.bounds.width - rect.origin.x - 8, 200)
        let boundingRect = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )

        // isFlipped = true in CodeEditTextView, so y=0 is top — coords match layoutManager directly
        layer.frame = CGRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: ceil(boundingRect.width) + 4,
            height: ceil(boundingRect.height) + 2
        )
        layer.isWrapped = true

        textView.layer?.addSublayer(layer)
        ghostLayer = layer
        installScrollObserver()
    }

    func hide() {
        ghostLayer?.removeFromSuperlayer()
        ghostLayer = nil
        currentText = nil
        removeScrollObserver()
    }

    func uninstall() {
        hide()
        removeScrollObserver()
        controller = nil
    }

    // MARK: - Scroll Observer

    private func installScrollObserver() {
        guard _scrollObserver.withLock({ $0 }) == nil else { return }
        guard let scrollView = controller?.scrollView else { return }
        let contentView = scrollView.contentView

        _scrollObserver.withLock {
            $0 = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.repositionGhostLayer()
                }
            }
        }
    }

    private func removeScrollObserver() {
        _scrollObserver.withLock {
            if let observer = $0 {
                NotificationCenter.default.removeObserver(observer)
            }
            $0 = nil
        }
    }

    private func repositionGhostLayer() {
        guard let ghostLayer, let controller, let textView = controller.textView else { return }
        guard let rect = textView.layoutManager.rectForOffset(currentOffset) else { return }
        var frame = ghostLayer.frame
        frame.origin = rect.origin
        ghostLayer.frame = frame
    }
}
