//
//  VimCursorManager.swift
//  TablePro
//
//  Manages the block cursor overlay for Vim mode in the SQL editor.
//  Shows a block cursor (character-width rectangle) in Normal/Visual modes
//  and hides it to show the default I-beam cursor in Insert mode.
//
//  On macOS 14+, CodeEditTextView uses NSTextInsertionIndicator (system cursor)
//  instead of its internal CursorView. Setting insertionPointColor only affects
//  CursorView, so we must directly set displayMode on NSTextInsertionIndicator
//  subviews to hide/show the I-beam.
//

import AppKit
import CodeEditTextView
import os

/// Manages Vim-style block cursor rendering on the text view
@MainActor
final class VimCursorManager {
    // MARK: - Properties

    private static let logger = Logger(subsystem: "com.TablePro", category: "VimCursor")

    private weak var textView: TextView?
    private var blockCursorLayer: CALayer?
    private var isBlockCursorActive = false

    /// Pending work item for deferred cursor hiding — cancels previous to avoid pileup
    private var deferredHideWorkItem: DispatchWorkItem?

    // MARK: - Install / Uninstall

    /// Store the text view reference and show the block cursor for Normal mode
    func install(textView: TextView) {
        self.textView = textView
        updateMode(.normal)
    }

    /// Remove the block cursor layer and restore the system I-beam cursor
    func uninstall() {
        deferredHideWorkItem?.cancel()
        deferredHideWorkItem = nil
        removeBlockCursorLayer()
        showSystemCursor()
        isBlockCursorActive = false
        textView = nil
    }

    // MARK: - Mode Switching

    /// Switch cursor style based on the current Vim mode
    func updateMode(_ mode: VimMode) {
        guard textView != nil else { return }

        if mode.isInsert {
            // Insert mode: hide block cursor, restore I-beam
            removeBlockCursorLayer()
            showSystemCursor()
            isBlockCursorActive = false
        } else {
            // Normal, Visual, CommandLine: show block cursor, hide I-beam
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
        // CodeEditTextView creates after the selection change notification fires
        // (e.g., double-click word selection recreates NSTextInsertionIndicator views).
        hideSystemCursor()
        scheduleDeferredHide()

        let offset = cursorOffset ?? textView.selectedRange().location
        guard offset != NSNotFound else {
            removeBlockCursorLayer()
            return
        }

        guard let rect = textView.layoutManager.rectForOffset(offset) else {
            removeBlockCursorLayer()
            return
        }

        // Calculate character width from the editor font
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
            // Reuse existing layer — just update frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            existingLayer.frame = frame
            CATransaction.commit()
        } else {
            // Create new layer
            let layer = CALayer()
            layer.contentsScale = textView.window?.backingScaleFactor ?? 2.0
            layer.backgroundColor = ThemeEngine.shared.colors.editor.cursor.withAlphaComponent(0.4).cgColor
            layer.frame = frame

            // Add blink animation
            let blinkAnimation = CABasicAnimation(keyPath: "opacity")
            blinkAnimation.fromValue = 1.0
            blinkAnimation.toValue = 0.0
            blinkAnimation.duration = 0.5
            blinkAnimation.autoreverses = true
            blinkAnimation.repeatCount = .infinity
            layer.add(blinkAnimation, forKey: "blink")

            textView.layer?.addSublayer(layer)
            blockCursorLayer = layer
        }
    }

    // MARK: - Private Helpers

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

    /// Hide the system I-beam cursor (NSTextInsertionIndicator on macOS 14+)
    private func hideSystemCursor() {
        guard let textView else { return }
        for subview in textView.subviews {
            if let indicator = subview as? NSTextInsertionIndicator {
                indicator.displayMode = .hidden
            }
        }
    }

    /// Restore the system I-beam cursor to automatic display
    private func showSystemCursor() {
        guard let textView else { return }
        for subview in textView.subviews {
            if let indicator = subview as? NSTextInsertionIndicator {
                indicator.displayMode = .automatic
            }
        }
    }
}
