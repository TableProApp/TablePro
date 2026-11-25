//
//  ProjectPopUpButton.swift
//  TablePro
//

import AppKit

internal struct ProjectPopUpActions {
    let select: (UUID?) -> Void
    let newProject: () -> Void
    let manageProjects: () -> Void
}

// A pop-up button shows the scope in force as its own title; a menu toolbar item shows only an image.
@MainActor
internal final class ProjectPopUpController: NSObject {
    internal static let maximumWidth: CGFloat = 220

    var actions: ProjectPopUpActions
    private(set) var entries: [ProjectMenuEntry] = []
    private weak var button: NSPopUpButton?

    init(actions: ProjectPopUpActions) {
        self.actions = actions
    }

    static func makeButton() -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        if #available(macOS 14.0, *) {
            button.bezelStyle = .toolbar
        } else {
            button.bezelStyle = .texturedRounded
        }
        button.lineBreakMode = .byTruncatingTail
        button.setAccessibilityLabel(String(localized: "Project"))
        button.setAccessibilityIdentifier("welcome-project-switcher")
        button.widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth).isActive = true
        return button
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
