//
//  WelcomeImportMenuButton.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct WelcomeImportActions {
    let importConnectionsFile: () -> Void
    let importFromURL: () -> Void
    let importFromApp: () -> Void
    let importFromAWS: () -> Void
    let openProjectFolder: () -> Void
}

internal struct WelcomeImportMenuButton: NSViewRepresentable {
    let actions: WelcomeImportActions

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .push
        button.alignment = .center
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setAccessibilityIdentifier("welcome-import-menu")
        button.menu = context.coordinator.makeMenu()
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.actions = actions
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        guard let width = proposal.width, width.isFinite else { return intrinsic }
        return CGSize(width: max(width, intrinsic.width), height: intrinsic.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions)
    }

    @MainActor
    internal final class Coordinator: NSObject {
        var actions: WelcomeImportActions

        init(actions: WelcomeImportActions) {
            self.actions = actions
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: String(localized: "Import"), action: nil, keyEquivalent: ""))
            for command in ImportCommand.allCases {
                if command.startsGroup {
                    menu.addItem(.separator())
                }
                menu.addItem(item(command))
            }
            return menu
        }

        @objc
        func runCommand(_ sender: NSMenuItem) {
            guard let command = ImportCommand(rawValue: sender.tag) else { return }
            switch command {
            case .connectionsFile: actions.importConnectionsFile()
            case .url: actions.importFromURL()
            case .otherApp: actions.importFromApp()
            case .aws: actions.importFromAWS()
            case .projectFolder: actions.openProjectFolder()
            }
        }

        private func item(_ command: ImportCommand) -> NSMenuItem {
            let item = NSMenuItem(title: command.title, action: #selector(runCommand(_:)), keyEquivalent: "")
            item.target = self
            item.tag = command.rawValue
            return item
        }
    }
}
