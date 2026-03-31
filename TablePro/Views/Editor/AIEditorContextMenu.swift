//
//  AIEditorContextMenu.swift
//  TablePro
//
//  Context menu for the SQL editor with AI integration features.
//

import AppKit

/// Context menu for the SQL editor that adds AI features alongside standard editing items
final class AIEditorContextMenu: NSMenu, NSMenuDelegate {
    /// Closure provided by the coordinator to check if text is selected
    var hasSelection: (() -> Bool)?
    var selectedText: (() -> String?)?
    var fullText: (() -> String?)?
    var onExplainWithAI: ((String) -> Void)?
    var onOptimizeWithAI: ((String) -> Void)?
    var onSaveAsFavorite: ((String) -> Void)?
    var onFormatSQL: (() -> Void)?

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
        menu.removeAllItems()

        // Standard editing items
        let cutItem = NSMenuItem(title: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(cutItem)

        let copyItem = NSMenuItem(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "")
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        let selectAllItem = NSMenuItem(title: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        menu.addItem(selectAllItem)

        menu.addItem(.separator())

        let formatItem = NSMenuItem(
            title: String(localized: "Format SQL"),
            action: #selector(handleFormatSQL),
            keyEquivalent: ""
        )
        formatItem.target = self
        formatItem.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)
        formatItem.isEnabled = (fullText?()?.isEmpty == false) && (onFormatSQL != nil)
        menu.addItem(formatItem)

        menu.addItem(.separator())

        let saveAsFavItem = NSMenuItem(
            title: String(localized: "Save as Favorite..."),
            action: #selector(handleSaveAsFavorite),
            keyEquivalent: ""
        )
        saveAsFavItem.target = self
        saveAsFavItem.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        saveAsFavItem.isEnabled = (fullText?()?.isEmpty == false)
        menu.addItem(saveAsFavItem)

        // AI items — only when text is selected
        guard AppSettingsManager.shared.ai.enabled, hasSelection?() == true else { return }

        menu.addItem(.separator())

        let explainItem = NSMenuItem(
            title: String(localized: "Explain with AI"),
            action: #selector(handleExplainWithAI),
            keyEquivalent: ""
        )
        explainItem.target = self
        explainItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(explainItem)

        let optimizeItem = NSMenuItem(
            title: String(localized: "Optimize with AI"),
            action: #selector(handleOptimizeWithAI),
            keyEquivalent: ""
        )
        optimizeItem.target = self
        optimizeItem.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: nil)
        menu.addItem(optimizeItem)
    }

    // MARK: - AI Actions

    @objc private func handleExplainWithAI() {
        guard let text = selectedText?() else { return }
        onExplainWithAI?(text)
    }

    @objc private func handleOptimizeWithAI() {
        guard let text = selectedText?() else { return }
        onOptimizeWithAI?(text)
    }

    @objc private func handleFormatSQL() {
        onFormatSQL?()
    }

    @objc private func handleSaveAsFavorite() {
        if let text = selectedText?(), !text.isEmpty {
            onSaveAsFavorite?(text)
        } else if let text = fullText?(), !text.isEmpty {
            onSaveAsFavorite?(text)
        }
    }
}
