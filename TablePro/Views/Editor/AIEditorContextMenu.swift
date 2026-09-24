//
//  AIEditorContextMenu.swift
//  TablePro
//
//  Context menu for the SQL editor with AI integration features.
//

import AppKit

/// Context menu for the SQL editor that adds AI features alongside standard editing items
final class AIEditorContextMenu: NSMenu, NSMenuDelegate {
    var fullText: (() -> String?)?
    var selection: (() -> EditorContextSelection)?
    var aiAvailability: (() -> AIQueryActionAvailability)?
    var onAIAction: ((AIQueryAction) -> Void)?
    var onSaveAsFavorite: ((String) -> Void)?
    var onFormatSQL: ((NSRange) -> Void)?
    /// Whether the cursor sits inside a collapsed fold. `nil` when there is no fold at the cursor.
    var foldStateAtCursor: (() -> Bool?)?
    var onToggleFold: (() -> Void)?

    override init(title: String) {
        super.init(title: title)
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        let groups = [editingItems, [selectAllItem], formattingItems, favoriteItems, aiItems]
            .filter { !$0.isEmpty }
        menu.items = groups.enumerated().flatMap { index, group in
            index == 0 ? group : [NSMenuItem.separator()] + group
        }
    }

    private var hasText: Bool {
        fullText?()?.isEmpty == false
    }

    private var editingItems: [NSMenuItem] {
        [
            NSMenuItem(title: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: ""),
            NSMenuItem(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: ""),
            NSMenuItem(title: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "")
        ]
    }

    private var selectAllItem: NSMenuItem {
        NSMenuItem(title: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
    }

    private var formattingItems: [NSMenuItem] {
        [formatItem, foldItem].compactMap { $0 }
    }

    private var formatItem: NSMenuItem? {
        guard hasText, onFormatSQL != nil else { return nil }
        let item = NSMenuItem(title: String(localized: "Format SQL"), action: #selector(handleFormatSQL), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)
        return item
    }

    private var foldItem: NSMenuItem? {
        guard onToggleFold != nil, let collapsed = foldStateAtCursor?() else { return nil }
        let item = NSMenuItem(
            title: collapsed ? String(localized: "Unfold") : String(localized: "Fold"),
            action: #selector(handleToggleFold),
            keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(
            systemSymbolName: collapsed ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
            accessibilityDescription: nil
        )
        return item
    }

    private var favoriteItems: [NSMenuItem] {
        guard hasText, onSaveAsFavorite != nil else { return [] }
        let item = NSMenuItem(
            title: String(localized: "Save as Favorite…"),
            action: #selector(handleSaveAsFavorite),
            keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        return [item]
    }

    private var aiItems: [NSMenuItem] {
        guard onAIAction != nil, aiAvailability?().isEnabled == true else { return [] }
        return AIQueryAction.editorActions.map { Self.aiMenuItem(for: $0, target: self) }
    }

    private static func aiMenuItem(for action: AIQueryAction, target: AIEditorContextMenu) -> NSMenuItem {
        let item = NSMenuItem(title: action.menuTitle, action: #selector(handleAIAction(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = action.rawValue
        item.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
        return item
    }

    private var effectiveSelection: NSRange {
        selection?().effectiveRange ?? NSRange(location: 0, length: 0)
    }

    // MARK: - AI Actions

    @objc private func handleAIAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let action = AIQueryAction(rawValue: rawValue) else { return }
        onAIAction?(action)
    }

    @objc private func handleToggleFold() {
        onToggleFold?()
    }

    @objc private func handleFormatSQL() {
        onFormatSQL?(effectiveSelection)
    }

    @objc private func handleSaveAsFavorite() {
        guard let text = fullText?(), !text.isEmpty else { return }
        let selected = selection?().selectedText(in: text)
        onSaveAsFavorite?(selected ?? text)
    }
}
