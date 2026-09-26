import AppKit
import Combine
import Foundation
import os
import TableProSyncTransport

@MainActor
final class AppSettingsManager: ObservableObject {
    static let shared = AppSettingsManager()

    @Published var general: GeneralSettings {
        didSet {
            general.language.apply()
            storage.saveGeneral(general)
            if oldValue.showWorkspaceRail != general.showWorkspaceRail {
                appEvents.workspaceRailVisibilityChanged.send(())
            }
            if oldValue.connectionHealthCheck != general.connectionHealthCheck {
                appEvents.connectionHealthCheckChanged.send(())
            }
            syncTracker.markDirty(.settings, id: AppSettingsCategory.general)
        }
    }

    @Published var appearance: AppearanceSettings {
        didSet {
            storage.saveAppearance(appearance)
            themeEngine.updateAppearanceAndTheme(
                mode: appearance.appearanceMode,
                lightThemeId: appearance.preferredLightThemeId,
                darkThemeId: appearance.preferredDarkThemeId
            )
            syncTracker.markDirty(.settings, id: AppSettingsCategory.appearance)
        }
    }

    @Published var editor: EditorSettings {
        didSet {
            storage.saveEditor(editor)
            themeEngine.updateEditorSettings(
                highlightCurrentLine: editor.highlightCurrentLine,
                highlightCurrentStatement: editor.highlightCurrentStatement,
                showLineNumbers: editor.showLineNumbers,
                tabWidth: editor.clampedTabWidth,

                wordWrap: editor.wordWrap
            )
            appEvents.editorSettingsChanged.send(())
            syncTracker.markDirty(.settings, id: AppSettingsCategory.editor)
        }
    }

    @Published var notifications: NotificationSettings {
        didSet {
            guard !isValidating else { return }
            var validated = notifications
            validated.thresholdSeconds = notifications.validatedThresholdSeconds
            if validated != notifications {
                isValidating = true
                notifications = validated
                isValidating = false
            }
            storage.saveNotifications(notifications)
            syncTracker.markDirty(.settings, id: AppSettingsCategory.notifications)
        }
    }

    @Published var dataGrid: DataGridSettings {
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
            dateFormattingService.updateFormat(validated.dateFormat)
            appEvents.dataGridSettingsChanged.send(())
            syncTracker.markDirty(.settings, id: AppSettingsCategory.dataGrid)
        }
    }

    @Published var history: HistorySettings {
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
            syncTracker.markDirty(.settings, id: AppSettingsCategory.history)
        }
    }

    @Published var tabs: TabSettings {
        didSet {
            storage.saveTabs(tabs)
            syncTracker.markDirty(.settings, id: AppSettingsCategory.tabs)
        }
    }

    @Published var keyboard: KeyboardSettings {
        didSet {
            storage.saveKeyboard(keyboard)
            syncTracker.markDirty(.settings, id: AppSettingsCategory.keyboard)
            MainMenuBuilder.syncKeyEquivalents(keyboard: keyboard)
            appEvents.keyboardSettingsChanged.send(())
        }
    }

    @Published var ai: AISettings {
        didSet {
            storage.saveAI(ai)
            syncTracker.markDirty(.settings, id: AppSettingsCategory.ai)
            appEvents.aiSettingsChanged.send(())
            let hadCopilot = oldValue.providers.contains(where: { $0.type == .copilot })
            let hasCopilot = ai.providers.contains(where: { $0.type == .copilot })
            if hasCopilot != hadCopilot {
                Task { [copilotService] in
                    if hasCopilot {
                        await copilotService.start()
                    } else {
                        await copilotService.stop()
                    }
                }
            }
        }
    }

    @Published var sync: SyncSettings {
        didSet {
            storage.saveSync(sync)
        }
    }

    @Published var mcp: MCPSettings {
        didSet {
            guard !isValidating else { return }
            var validated = mcp
            validated.maxRowLimit = mcp.validatedMaxRowLimit
            validated.defaultRowLimit = mcp.validatedDefaultRowLimit
            validated.queryTimeoutSeconds = mcp.validatedQueryTimeoutSeconds
            if validated != mcp {
                isValidating = true
                mcp = validated
                isValidating = false
            }

            storage.saveMCP(validated)
            let enabledChanged = mcp.enabled != oldValue.enabled
            let portChanged = mcp.port != oldValue.port
            let authChanged = mcp.requireAuthentication != oldValue.requireAuthentication
            if enabledChanged || portChanged || authChanged {
                if mcp.enabled {
                    mcpServerManager.scheduleRestart(port: UInt16(clamping: mcp.port))
                } else {
                    mcpServerManager.scheduleStop()
                }
            }
        }
    }

    @MainActor
    func setRequireAuthentication(_ value: Bool) async -> (token: MCPAuthToken, plaintext: String)? {
        guard value, !mcp.requireAuthentication else {
            mcp.requireAuthentication = value
            return nil
        }

        let tokenStore = mcpServerManager.tokenStore ?? MCPTokenStore()
        if mcpServerManager.tokenStore == nil {
            await tokenStore.loadFromDisk()
        }
        let existing = await tokenStore.list().filter { !$0.isBridgeCredential }
        guard existing.isEmpty else {
            mcp.requireAuthentication = value
            return nil
        }

        let defaultName = String(localized: "Default token")
        let result = try? await tokenStore.generate(
            name: defaultName,
            permissions: .readWrite,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: false
        )
        mcp.requireAuthentication = value
        return result
    }

    private let storage: AppSettingsStorage
    private let themeEngine: ThemeEngine
    private let syncTracker: SyncChangeTracker
    private let appEvents: AppEvents
    private let dateFormattingService: DateFormattingService
    private let queryHistoryManager: QueryHistoryManager
    private let mcpServerManager: MCPServerManager
    private let copilotService: CopilotService
    private let connectionListPreferences: ConnectionListPreferences
    private var isValidating = false

    init(
        storage: AppSettingsStorage = .shared,
        themeEngine: ThemeEngine = .shared,
        syncTracker: SyncChangeTracker = .shared,
        appEvents: AppEvents = .shared,
        dateFormattingService: DateFormattingService = .shared,
        queryHistoryManager: QueryHistoryManager = .shared,
        mcpServerManager: MCPServerManager = .shared,
        copilotService: CopilotService = .shared,
        connectionListPreferences: ConnectionListPreferences = .shared
    ) {
        self.storage = storage
        self.themeEngine = themeEngine
        self.syncTracker = syncTracker
        self.appEvents = appEvents
        self.dateFormattingService = dateFormattingService
        self.queryHistoryManager = queryHistoryManager
        self.mcpServerManager = mcpServerManager
        self.copilotService = copilotService
        self.connectionListPreferences = connectionListPreferences

        self.general = storage.loadGeneral()
        self.appearance = storage.loadAppearance()
        self.editor = storage.loadEditor()
        self.dataGrid = storage.loadDataGrid()
        self.history = storage.loadHistory()
        self.tabs = storage.loadTabs()
        self.keyboard = storage.loadKeyboard()
        self.ai = Self.migrateAI(storage.loadAI())
        self.sync = storage.loadSync()
        self.mcp = storage.loadMCP()
        self.notifications = storage.loadNotifications()

        general.language.apply()

        themeEngine.updateAppearanceAndTheme(
            mode: appearance.appearanceMode,
            lightThemeId: appearance.preferredLightThemeId,
            darkThemeId: appearance.preferredDarkThemeId
        )

        themeEngine.updateEditorSettings(
            highlightCurrentLine: editor.highlightCurrentLine,
            highlightCurrentStatement: editor.highlightCurrentStatement,
            showLineNumbers: editor.showLineNumbers,
            tabWidth: editor.clampedTabWidth,
            wordWrap: editor.wordWrap
        )

        dateFormattingService.updateFormat(dataGrid.dateFormat)

        if ai.enabled, ai.providers.contains(where: { $0.type == .copilot }) {
            Task { [copilotService] in await copilotService.start() }
        }
    }

    /// Auto-pick the first configured provider as active when nothing is selected.
    /// Avoids a "AI suddenly stopped working" upgrade UX when older settings JSON
    /// (with multiple providers and no activeProviderID concept) is loaded.
    /// Internal so `@testable` tests can exercise it directly.
    internal static func migrateAI(_ settings: AISettings) -> AISettings {
        guard settings.activeProviderID == nil, let first = settings.providers.first else {
            return settings
        }
        var migrated = settings
        migrated.activeProviderID = first.id
        return migrated
    }

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "AppSettingsManager")

    private func applyHistorySettingsImmediately() async {
        await queryHistoryManager.applySettingsChange()
    }

    /// The update preferences belong to Sparkle rather than to the structs reassigned above, so
    /// they are cleared here and not by the caller: the alert promises every section, and a second
    /// reset entry point would otherwise skip them silently.
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
        mcp = .default
        storage.resetToDefaults()
        connectionListPreferences.resetShowsRecent()
        SoftwareUpdater.shared.resetUpdatePreferences()
    }
}
