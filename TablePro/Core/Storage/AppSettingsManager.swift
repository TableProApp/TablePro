//
//  AppSettingsManager.swift
//  TablePro
//
//  Observable settings manager for real-time UI updates.
//  Uses @Published properties with didSet for immediate persistence.
//

import AppKit
import Foundation
import Observation
import os

/// Observable settings manager for immediate persistence and live updates
@Observable
@MainActor
final class AppSettingsManager {
    static let shared = AppSettingsManager()

    deinit {
        if let observer = accessibilityTextSizeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Published Settings

    var general: GeneralSettings {
        didSet {
            general.language.apply()
            storage.saveGeneral(general)
            SyncChangeTracker.shared.markDirty(.settings, id: "general")
        }
    }

    var appearance: AppearanceSettings {
        didSet {
            storage.saveAppearance(appearance)
            ThemeEngine.shared.activateTheme(id: appearance.activeThemeId)
            ThemeEngine.shared.updateAppearanceMode(appearance.appearanceMode)
            SyncChangeTracker.shared.markDirty(.settings, id: "appearance")
        }
    }

    var editor: EditorSettings {
        didSet {
            storage.saveEditor(editor)
            // Update behavioral settings in ThemeEngine
            ThemeEngine.shared.updateEditorSettings(
                highlightCurrentLine: editor.highlightCurrentLine,
                showLineNumbers: editor.showLineNumbers,
                tabWidth: editor.clampedTabWidth,
                autoIndent: editor.autoIndent,
                wordWrap: editor.wordWrap
            )
            notifyChange(.editorSettingsDidChange)
            SyncChangeTracker.shared.markDirty(.settings, id: "editor")
        }
    }

    var dataGrid: DataGridSettings {
        didSet {
            guard !isValidating else { return }
            // Validate and sanitize before saving
            var validated = dataGrid
            validated.nullDisplay = dataGrid.validatedNullDisplay
            validated.defaultPageSize = dataGrid.validatedDefaultPageSize

            // Store validated values back so in-memory state matches persisted state
            if validated != dataGrid {
                isValidating = true
                dataGrid = validated
                isValidating = false
            }

            storage.saveDataGrid(validated)
            // Update date formatting service with new format
            DateFormattingService.shared.updateFormat(validated.dateFormat)
            notifyChange(.dataGridSettingsDidChange)
            SyncChangeTracker.shared.markDirty(.settings, id: "dataGrid")
        }
    }

    var history: HistorySettings {
        didSet {
            guard !isValidating else { return }
            // Validate before saving
            var validated = history
            validated.maxEntries = history.validatedMaxEntries
            validated.maxDays = history.validatedMaxDays

            // Store validated values back so in-memory state matches persisted state
            if validated != history {
                isValidating = true
                history = validated
                isValidating = false
            }

            storage.saveHistory(validated)
            // Apply history settings immediately (cleanup if auto-cleanup enabled)
            Task { await applyHistorySettingsImmediately() }
            SyncChangeTracker.shared.markDirty(.settings, id: "history")
        }
    }

    var tabs: TabSettings {
        didSet {
            storage.saveTabs(tabs)
            SyncChangeTracker.shared.markDirty(.settings, id: "tabs")
        }
    }

    var keyboard: KeyboardSettings {
        didSet {
            storage.saveKeyboard(keyboard)
            SyncChangeTracker.shared.markDirty(.settings, id: "keyboard")
        }
    }

    var ai: AISettings {
        didSet {
            storage.saveAI(ai)
            SyncChangeTracker.shared.markDirty(.settings, id: "ai")
        }
    }

    var sync: SyncSettings {
        didSet {
            storage.saveSync(sync)
            SyncChangeTracker.shared.markDirty(.settings, id: "sync")
        }
    }

    @ObservationIgnored private let storage = AppSettingsStorage.shared
    /// Reentrancy guard for didSet validation that re-assigns the property.
    @ObservationIgnored private var isValidating = false
    @ObservationIgnored private var accessibilityTextSizeObserver: NSObjectProtocol?
    /// Tracks the last-seen accessibility scale factor to avoid redundant reloads.
    /// The accessibility display options notification fires for all display option changes
    /// (contrast, motion, etc.), not just text size.
    @ObservationIgnored private var lastAccessibilityScale: CGFloat = 1.0

    // MARK: - Initialization

    private init() {
        // Load all settings on initialization
        self.general = storage.loadGeneral()
        self.appearance = storage.loadAppearance()
        self.editor = storage.loadEditor()
        self.dataGrid = storage.loadDataGrid()
        self.history = storage.loadHistory()
        self.tabs = storage.loadTabs()
        self.keyboard = storage.loadKeyboard()
        self.ai = storage.loadAI()
        self.sync = storage.loadSync()

        // Apply language immediately
        general.language.apply()

        // ThemeEngine initializes itself from persisted theme ID
        // Apply app-level appearance mode
        ThemeEngine.shared.updateAppearanceMode(appearance.appearanceMode)

        // Sync editor behavioral settings to ThemeEngine
        ThemeEngine.shared.updateEditorSettings(
            highlightCurrentLine: editor.highlightCurrentLine,
            showLineNumbers: editor.showLineNumbers,
            tabWidth: editor.clampedTabWidth,
            autoIndent: editor.autoIndent,
            wordWrap: editor.wordWrap
        )

        // Initialize DateFormattingService with current format
        DateFormattingService.shared.updateFormat(dataGrid.dateFormat)

        // Observe system accessibility text size changes and re-apply editor fonts
        observeAccessibilityTextSizeChanges()
    }

    // MARK: - Notification Propagation

    private func notifyChange(_ notification: Notification.Name) {
        NotificationCenter.default.post(name: notification, object: self)
    }

    // MARK: - Accessibility Text Size

    private static let logger = Logger(subsystem: "com.TablePro", category: "AppSettingsManager")

    /// Observe the system accessibility text size preference and reload editor fonts when it changes.
    /// Uses NSWorkspace.accessibilityDisplayOptionsDidChangeNotification which fires when the user
    /// changes settings in System Settings > Accessibility > Display (including the Text Size slider).
    private func observeAccessibilityTextSizeChanges() {
        lastAccessibilityScale = EditorFontCache.computeAccessibilityScale()
        accessibilityTextSizeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newScale = EditorFontCache.computeAccessibilityScale()
                guard abs(newScale - lastAccessibilityScale) > 0.01 else { return }
                lastAccessibilityScale = newScale
                Self.logger.debug("Accessibility text size changed, scale: \(newScale, format: .fixed(precision: 2))")
                ThemeEngine.shared.reloadFontCaches()
                NotificationCenter.default.post(name: .accessibilityTextSizeDidChange, object: self)
            }
        }
    }

    private func applyHistorySettingsImmediately() async {
        QueryHistoryManager.shared.applySettingsChange()
    }

    // MARK: - Actions

    /// Reset all settings to defaults
    func resetToDefaults() {
        general = .default
        appearance = .default
        editor = .default
        dataGrid = .default
        history = .default
        tabs = .default
        keyboard = .default
        ai = .default
        sync = .default
        storage.resetToDefaults()
    }
}
