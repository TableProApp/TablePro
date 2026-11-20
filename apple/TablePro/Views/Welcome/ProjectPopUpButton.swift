//
//  ProjectPopUpButton.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct ProjectPopUpActions {
    let select: (UUID?) -> Void
    let newProject: () -> Void
    let manageProjects: () -> Void
}

// A pop-up button shows the scope in force as its own title. A SwiftUI `Picker` cannot carry the two
// commands under the list.
internal struct ProjectPopUpButton: NSViewRepresentable {
    internal static let maximumWidth: CGFloat = 220

    let projects: [ConnectionProject]
    let activeProjectId: UUID?
    let actions: ProjectPopUpActions

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        if #available(macOS 14.0, *) {
            button.bezelStyle = .toolbar
        } else {
            button.bezelStyle = .texturedRounded
        }
        button.lineBreakMode = .byTruncatingTail
        button.setAccessibilityLabel(String(localized: "Project"))
        button.setAccessibilityIdentifier("welcome-project-switcher")
        context.coordinator.apply(entries, to: button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.apply(entries, to: button)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(width: min(intrinsic.width, Self.maximumWidth), height: intrinsic.height)
    }

    private var entries: [ProjectMenuEntry] {
        ProjectMenuModel.entries(projects: projects, activeProjectId: activeProjectId)
    }

    @MainActor
    internal final class Coordinator: NSObject {
        var actions: ProjectPopUpActions
        private(set) var entries: [ProjectMenuEntry] = []
        private weak var button: NSPopUpButton?

        init(actions: ProjectPopUpActions) {
            self.actions = actions
        }

        func apply(_ entries: [ProjectMenuEntry], to button: NSPopUpButton) {
            self.button = button
            if entries != self.entries {
                self.entries = entries
                let menu = NSMenu()
                let selectors = ProjectMenuModel.Actions(
                    select: #selector(selectScope(_:)),
                    newProject: #selector(newProject(_:)),
                    manageProjects: #selector(manageProjects(_:))
                )
                for item in ProjectMenuModel.items(for: entries, actions: selectors, target: self) {
                    menu.addItem(item)
                }
                button.menu = menu
            }
            showActiveScope()
        }

        // The button checks whatever row was picked. A command row is not a scope, so the title goes
        // back to the one in force.
        private func showActiveScope() {
            guard let button else { return }
            let active = entries.firstIndex { entry in
                if case .scope(_, _, true) = entry { return true }
                return false
            }
            guard let active, button.indexOfSelectedItem != active else { return }
            button.selectItem(at: active)
        }

        @objc
        func selectScope(_ sender: NSMenuItem) {
            actions.select(sender.representedObject as? UUID)
        }

        @objc
        func newProject(_ sender: NSMenuItem) {
            showActiveScope()
            actions.newProject()
        }

        @objc
        func manageProjects(_ sender: NSMenuItem) {
            showActiveScope()
            actions.manageProjects()
        }
    }
}
