//
//  QuickSwitcherPanelController.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
final class QuickSwitcherPanelController {
    private var panel: NSPanel?
    private var resignKeyObserver: NSObjectProtocol?

    func show(
        schemaProvider: SQLSchemaProvider,
        connectionId: UUID,
        databaseType: DatabaseType,
        onSelect: @escaping (QuickSwitcherItem) -> Void
    ) {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let dismissAction: () -> Void = { [weak self] in
            self?.dismiss()
        }

        let content = QuickSwitcherContentView(
            schemaProvider: schemaProvider,
            connectionId: connectionId,
            databaseType: databaseType,
            onSelect: { [weak self] item in
                onSelect(item)
                self?.dismiss()
            },
            onDismiss: dismissAction
        )

        let host = NSHostingController(rootView: content)
        host.preferredContentSize = NSSize(width: 460, height: 480)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "Quick Switcher")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentViewController = host
        panel.center()

        self.panel = panel

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }

        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        if let observer = resignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            resignKeyObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }
}
