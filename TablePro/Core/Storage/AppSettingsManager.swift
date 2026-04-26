import AppKit
import Foundation
import Observation
import os

@Observable
@MainActor
final class AppSettingsManager {
    static let shared = AppSettingsManager()

    deinit {
        if let observer = accessibilityTextSizeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

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
            ThemeEngine.shared.updateAppearanceAndTheme(
                mode: appearance.appearanceMode,
                lightThemeId: appearance.preferredLightThemeId,
                darkThemeId: appearance.preferredDarkThemeId
            )
            SyncChangeTracker.shared.markDirty(.settings, id: "appearance")
        }
    }

    var editor: EditorSettings {
        didSet {
            storage.saveEditor(editor)
            ThemeEngine.shared.updateEditorSettings(
                highlightCurrentLine: editor.highlightCurrentLine,
                showLineNumbers: editor.showLineNumbers,
                tabWidth: editor.clampedTabWidth,

                wordWrap: editor.wordWrap
            )
            notifyChange(.editorSettingsDidChange)
            SyncChangeTracker.shared.markDirty(.settings, id: "editor")
        }
    }

    var dataGrid: DataGridSettings {
        didSet {
            guard !isValidating else { return }
            var validated = dataGrid
            validated.nullDisplay = dataGrid.validatedNullDisplay
            validated.defaultPageSize = dataGrid.validatedDefaultPageSize

            if validated != dataGrid {
                isValidating = true
                dataGrid = validated
                isValidating = false
            }

            storage.saveDataGrid(validated)
            DateFormattingService.shared.updateFormat(validated.dateFormat)
            notifyChange(.dataGridSettingsDidChange)
            SyncChangeTracker.shared.markDirty(.settings, id: "dataGrid")
        }
    }

    var history: HistorySettings {
        didSet {
            guard !isValidating else { return }
            var validated = history
            validated.maxEntries = history.validatedMaxEntries
            validated.maxDays = history.validatedMaxDays

            if validated != history {
                isValidating = true
                history = validated
                isValidating = false
            }

            storage.saveHistory(validated)
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
            notifyChange(.aiSettingsDidChange)
            let hadCopilot = oldValue.providers.contains(where: { $0.type == .copilot })
            let hasCopilot = ai.providers.contains(where: { $0.type == .copilot })
            if hasCopilot != hadCopilot {
                Task {
                    if hasCopilot {
                        await CopilotService.shared.start()
                    } else {
                        await CopilotService.shared.stop()
                    }
                }
            }
        }
    }

    var sync: SyncSettings {
        didSet {
            storage.saveSync(sync)
            SyncChangeTracker.shared.markDirty(.settings, id: "sync")
        }
    }

    var terminal: TerminalSettings {
        didSet {
            storage.saveTerminal(terminal)
            notifyChange(.terminalSettingsDidChange)
            SyncChangeTracker.shared.markDirty(.settings, id: "terminal")
        }
    }

    var mcp: MCPSettings {
        didSet {
            guard !isValidating else { return }

            if mcp.allowRemoteConnections, !mcp.requireAuthentication {
                isValidating = true
                mcp.requireAuthentication = true
                isValidating = false
            }

            storage.saveMCP(mcp)
            SyncChangeTracker.shared.markDirty(.settings, id: "mcp")
            let enabledChanged = mcp.enabled != oldValue.enabled
            let portChanged = mcp.port != oldValue.port
            let remoteChanged = mcp.allowRemoteConnections != oldValue.allowRemoteConnections
            let authChanged = mcp.requireAuthentication != oldValue.requireAuthentication
            if enabledChanged || portChanged || remoteChanged || authChanged {
                let settings = mcp
                Task {
                    if settings.enabled {
                        await MCPServerManager.shared.restart(port: UInt16(clamping: settings.port))
                    } else {
                        await MCPServerManager.shared.stop()
                    }
                }
            }
        }
    }

    @ObservationIgnored private let storage = AppSettingsStorage.shared
    @ObservationIgnored private var isValidating = false
    @ObservationIgnored private var accessibilityTextSizeObserver: NSObjectProtocol?
    @ObservationIgnored private var lastAccessibilityScale: CGFloat = 1.0

    private init() {
        self.general = storage.loadGeneral()
        self.appearance = storage.loadAppearance()
        self.editor = storage.loadEditor()
        self.dataGrid = storage.loadDataGrid()
        self.history = storage.loadHistory()
        self.tabs = storage.loadTabs()
        self.keyboard = storage.loadKeyboard()
        self.ai = Self.migrateAI(storage.loadAI())
        self.sync = storage.loadSync()
        self.terminal = storage.loadTerminal()
        self.mcp = storage.loadMCP()

        general.language.apply()

        ThemeEngine.shared.updateAppearanceAndTheme(
            mode: appearance.appearanceMode,
            lightThemeId: appearance.preferredLightThemeId,
            darkThemeId: appearance.preferredDarkThemeId
        )

        ThemeEngine.shared.updateEditorSettings(
            highlightCurrentLine: editor.highlightCurrentLine,
            showLineNumbers: editor.showLineNumbers,
            tabWidth: editor.clampedTabWidth,
            wordWrap: editor.wordWrap
        )

        DateFormattingService.shared.updateFormat(dataGrid.dateFormat)

        observeAccessibilityTextSizeChanges()

        if ai.enabled, ai.providers.contains(where: { $0.type == .copilot }) {
            Task { await CopilotService.shared.start() }
        }
    }

    private func notifyChange(_ notification: Notification.Name) {
        NotificationCenter.default.post(name: notification, object: self)
    }

    /// Auto-pick the first configured provider as active when nothing is selected.
    /// Avoids a "AI suddenly stopped working" upgrade UX when older settings JSON
    /// (with multiple providers and no activeProviderID concept) is loaded.
    private static func migrateAI(_ settings: AISettings) -> AISettings {
        guard settings.activeProviderID == nil, let first = settings.providers.first else {
            return settings
        }
        var migrated = settings
        migrated.activeProviderID = first.id
        return migrated
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "AppSettingsManager")

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
        await QueryHistoryManager.shared.applySettingsChange()
    }

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
        terminal = .default
        mcp = .default
        storage.resetToDefaults()
    }
}
