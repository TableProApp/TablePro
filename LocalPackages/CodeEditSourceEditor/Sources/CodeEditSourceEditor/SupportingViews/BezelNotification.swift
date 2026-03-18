//
//  BezelNotification.swift
//  CodeEditSourceEditor
//
//  Created by Austin Condiff on 3/17/25.
//

import AppKit
import SwiftUI

/// A utility class for showing temporary bezel notifications with SF Symbols
final class BezelNotification {
    private static var shared = BezelNotification()
    private var window: NSWindow?
    private var hostingView: NSHostingView<BezelView>?
    private var frameObserver: NSObjectProtocol?
    private var targetView: NSView?
    private var hideTimer: DispatchWorkItem?

    private init() {}

    deinit {
        if let observer = frameObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Shows a bezel notification with the given SF Symbol name
    /// - Parameters:
    ///   - symbolName: The name of the SF Symbol to display
    ///   - over: The view to center the bezel over
    ///   - duration: How long to show the bezel for (defaults to 0.75 seconds)
    static func show(symbolName: String, over view: NSView, duration: TimeInterval = 0.75) {
        shared.showBezel(symbolName: symbolName, over: view, duration: duration)
    }

    private func showBezel(symbolName: String, over view: NSView, duration: TimeInterval) {
        // Cancel any existing hide timer
        hideTimer?.cancel()
        hideTimer = nil

        // Close existing window if any
        cleanup()

        self.targetView = view

        // Create the window and view
        let bezelContent = BezelView(symbolName: symbolName)
        let hostingView = NSHostingView(rootView: bezelContent)
        self.hostingView = hostingView

        let window = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: true
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.contentView = hostingView
        window.isMovable = false
        window.isReleasedWhenClosed = false

        // Make it a child window that moves with the parent
        if let parentWindow = view.window {
            parentWindow.addChildWindow(window, ordered: .above)
        }

        self.window = window

        // Size and position the window
        let size = NSSize(width: 110, height: 110)
        hostingView.frame.size = size

        // Initial position
        updateBezelPosition()

        // Observe frame changes
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: view,
            queue: .main
        ) { [weak self] _ in
            self?.updateBezelPosition()
        }

        // Show immediately without fade
        window.alphaValue = 1
        window.orderFront(nil)

        // Schedule hide
        let timer = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        self.hideTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: timer)
    }

    private func updateBezelPosition() {
        guard let window = window,
              let view = targetView else { return }

        let size = NSSize(width: 110, height: 110)

        // Position relative to the view's content area
        let visibleRect: NSRect
        if let scrollView = view.enclosingScrollView {
            // Get the visible rect in the scroll view's coordinate space
            visibleRect = scrollView.contentView.visibleRect
        } else {
            visibleRect = view.bounds
        }

        // Convert visible rect to window coordinates
        let viewFrameInWindow = view.enclosingScrollView?.contentView.convert(visibleRect, to: nil)
            ?? view.convert(visibleRect, to: nil)
        guard let screenFrame = view.window?.convertToScreen(viewFrameInWindow) else { return }

        // Calculate center position relative to the visible content area
        let xPos = screenFrame.midX - (size.width / 2)
        let yPos = screenFrame.midY - (size.height / 2)

        // Update frame
        let bezelFrame = NSRect(origin: NSPoint(x: xPos, y: yPos), size: size)
        window.setFrame(bezelFrame, display: true)
    }

    private func cleanup() {
        // Cancel any existing hide timer
        hideTimer?.cancel()
        hideTimer = nil

        // Remove frame observer
        if let observer = frameObserver {
            NotificationCenter.default.removeObserver(observer)
            frameObserver = nil
        }

        // Remove child window relationship
        if let window = window, let parentWindow = window.parent {
            parentWindow.removeChildWindow(window)
        }

        // Close and clean up window
        window?.orderOut(nil)  // Ensure window is removed from screen
        window?.close()
        window = nil

        // Clean up hosting view
        hostingView?.removeFromSuperview()
        hostingView = nil

        // Clear target view reference
        targetView = nil
    }

    private func dismiss() {
        guard let window = window else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.cleanup()
        })
    }
}

/// The SwiftUI view for the bezel content
private struct BezelView: View {
    let symbolName: String

    var body: some View {
        Image(systemName: symbolName)
            .imageScale(.large)
            .font(.system(size: 56, weight: .thin))
            .foregroundStyle(.secondary)
            .frame(width: 110, height: 110)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerSize: CGSize(width: 18.0, height: 18.0)))
    }
}
