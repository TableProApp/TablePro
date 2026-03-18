//
//  FindPanelViewModel.swift
//  CodeEditSourceEditor
//
//  Created by Austin Condiff on 3/12/25.
//

import SwiftUI
import Combine
import CodeEditTextView

class FindPanelViewModel: ObservableObject {
    enum Notifications {
        static let textDidChange = Notification.Name("FindPanelViewModel.textDidChange")
        static let replaceTextDidChange = Notification.Name("FindPanelViewModel.replaceTextDidChange")
        static let didToggle = Notification.Name("FindPanelViewModel.didToggle")
    }

    weak var target: FindPanelTarget?
    var dismiss: (() -> Void)?

    @Published var findMatches: [NSRange] = []
    @Published var currentFindMatchIndex: Int?
    @Published var isShowingFindPanel: Bool = false

    @Published var findText: String = ""
    @Published var replaceText: String = ""
    @Published var mode: FindPanelMode = .find {
        didSet {
            self.target?.findPanelModeDidChange(to: mode)
        }
    }

    @Published var findMethod: FindMethod = .contains {
        didSet {
            if !findText.isEmpty {
                find()
            }
        }
    }

    @Published var isFocused: Bool = false

    @Published var matchCase: Bool = false
    @Published var wrapAround: Bool = true

    /// The height of the find panel.
    var panelHeight: CGFloat {
        return mode == .replace ? 54 : 28
    }

    /// The number of current find matches.
    var matchCount: Int {
        findMatches.count
    }

    var matchesEmpty: Bool {
        matchCount == 0
    }

    var isTargetFirstResponder: Bool {
        target?.findPanelTargetView.window?.firstResponder === target?.findPanelTargetView
    }

    init(target: FindPanelTarget) {
        self.target = target

        // Add notification observer for text changes
        if let textViewController = target as? TextViewController {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textDidChange),
                name: TextView.textDidChangeNotification,
                object: textViewController.textView
            )
        }
    }

    // MARK: - Text Listeners

    /// Find target's text content changed, we need to re-search the contents and emphasize results.
    @objc private func textDidChange() {
        // Only update if we have find text
        if !findText.isEmpty {
            find()
        }
    }

    /// The contents of the find search field changed, trigger related events.
    func findTextDidChange() {
        // Check if this update was triggered by a return key without shift
        if let currentEvent = NSApp.currentEvent,
           currentEvent.type == .keyDown,
           currentEvent.keyCode == 36, // Return key
           !currentEvent.modifierFlags.contains(.shift) {
            return // Skip find for regular return key
        }

        // If the textview is first responder, exit fast
        if target?.findPanelTargetView.window?.firstResponder === target?.findPanelTargetView {
            // If the text view has focus, just clear visual emphases but keep our find matches
            target?.textView.emphasisManager?.removeEmphases(for: EmphasisGroup.find)
            return
        }

        // Clear existing emphases before performing new find
        target?.textView.emphasisManager?.removeEmphases(for: EmphasisGroup.find)
        find()

        NotificationCenter.default.post(name: Self.Notifications.textDidChange, object: target)
    }

    func replaceTextDidChange() {
        NotificationCenter.default.post(name: Self.Notifications.replaceTextDidChange, object: target)
    }
}
