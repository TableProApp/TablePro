//
//  VimCursorManager.swift
//  TablePro
//
//  Manages the block cursor overlay for Vim mode in the SQL editor.
//  Shows a block cursor (character-width rectangle) in Normal/Visual modes
//  and hides it to show the default I-beam cursor in Insert mode.
//

import AppKit
import os

/// Manages Vim-style block cursor rendering on the text view
@MainActor
final class VimCursorManager {
    // MARK: - Properties

    private static let logger = Logger(subsystem: "com.TablePro", category: "VimCursor")

    private weak var textView: NSTextView?
    private var blockCursorLayer: CALayer?
    private var isBlockCursorActive = false
    private var isPaused = false
    private var appObservers: [NSObjectProtocol] = []

    /// Pending work item for deferred cursor hiding — cancels previous to avoid pileup
    private var deferredHideWorkItem: DispatchWorkItem?

    // MARK: - Install / Uninstall

    /// Store the text view reference and show the block cursor for Normal mode
    func install(textView: NSTextView) {
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        appObservers.removeAll()

        self.textView = textView

        let resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseBlink() }
        }
        let activateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeBlink() }
        }
        appObservers = [resignObserver, activateObserver]

        updateMode(.normal)
    }

    /// Remove the block cursor layer and restore the system I-beam cursor
    func uninstall() {
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        appObservers.removeAll()

        deferredHideWorkItem?.cancel()
        deferredHideWorkItem = nil
        removeBlockCursorLayer()
        showSystemCursor()
        isBlockCursorActive = false
        isPaused = false
        textView = nil
    }

    // MARK: - Blink Control

    func pauseBlink() {
        isPaused = true
        blockCursorLayer?.removeAnimation(forKey: "blink")
        blockCursorLayer?.opacity = 1.0
    }

    func resumeBlink() {
        isPaused = false
        guard isBlockCursorActive, let layer = blockCursorLayer else { return }
        guard layer.animation(forKey: "blink") == nil else { return }
        layer.add(makeBlinkAnimation(), forKey: "blink")
    }

    // MARK: - Mode Switching

    /// Switch cursor style based on the current Vim mode
    func updateMode(_ mode: VimMode) {
        guard textView != nil else { return }

        if mode.isInsert {
            removeBlockCursorLayer()
            showSystemCursor()
            isBlockCursorActive = false
        } else {
            isBlockCursorActive = true
            hideSystemCursor()
            updatePosition()
        }
    }

    // MARK: - Position Update

    /// Reposition the block cursor at the given offset, or at the caret position if nil
    func updatePosition(cursorOffset: Int? = nil) {
        guard isBlockCursorActive else { return }
        guard let textView else {
            removeBlockCursorLayer()
            return
        }

        // Ensure system cursor stays hidden (it can be recreated during selection changes).
        // Hide immediately, then defer another hide to catch cursor views that
        // NSTextView may create the insertion indicator after the selection change notification fires
        // (e.g., double-click word selection recreates NSTextInsertionIndicator views).
        hideSystemCursor()
        scheduleDeferredHide()

        let offset = cursorOffset ?? textView.selectedRange().location
        guard offset != NSNotFound else {
            removeBlockCursorLayer()
            return
        }

        let rect = cursorRect(at: offset)
        guard rect != .zero else {
            removeBlockCursorLayer()
            return
        }

        let font = ThemeEngine.shared.editorFonts.font
        let charWidth = (NSString(" ").size(withAttributes: [.font: font])).width

        guard charWidth > 0 else {
            Self.logger.warning("Failed to calculate character width from editor font")
            removeBlockCursorLayer()
            return
        }

        let frame = CGRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: charWidth,
            height: rect.height
        )

        if let existingLayer = blockCursorLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            existingLayer.frame = frame
            CATransaction.commit()
        } else {
            let layer = CALayer()
            layer.contentsScale = textView.window?.backingScaleFactor ?? 2.0
            layer.backgroundColor = ThemeEngine.shared.colors.editor.cursor.withAlphaComponent(0.4).cgColor
            layer.frame = frame

            if !isPaused {
                layer.add(makeBlinkAnimation(), forKey: "blink")
            }

            textView.layer?.addSublayer(layer)
            blockCursorLayer = layer
        }
    }

    // MARK: - Private Helpers

    private func makeBlinkAnimation() -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.0
        animation.duration = 0.5
        animation.autoreverses = true
        animation.repeatCount = .infinity
        return animation
    }

    private func removeBlockCursorLayer() {
        blockCursorLayer?.removeFromSuperlayer()
        blockCursorLayer = nil
    }

    /// Schedule a deferred hide to catch cursor views recreated after selection changes
    private func scheduleDeferredHide() {
        deferredHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isBlockCursorActive else { return }
            self.hideSystemCursor()
        }
        deferredHideWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func cursorRect(at offset: Int) -> NSRect {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return .zero }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: offset, length: 1),
            actualCharacterRange: nil
        )
        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    }

    private func hideSystemCursor() {
        if let tpTextView = textView as? TPTextView {
            tpTextView.suppressSystemCursor = true
        }
    }

    private func showSystemCursor() {
        if let tpTextView = textView as? TPTextView {
            tpTextView.suppressSystemCursor = false
        }
    }
}
