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
            themeEngine.select(
                lightThemeId: appearance.preferredLightThemeId,
                darkThemeId: appearance.preferredDarkThemeId
            )
            syncTracker.markDirty(.settings, id: AppSettingsCategory.appearance)
        }
    }

    // Device-local, like typography: each Mac picks Auto, Light or Dark for itself.
    @Published var appearanceMode: AppAppearanceMode {
        didSet {
            guard appearanceMode != oldValue else { return }
            storage.saveAppearanceMode(appearanceMode)
            themeEngine.apply(mode: appearanceMode)
        }
    }

    @Published var editor: EditorSettings {
        didSet {
            storage.saveEditor(editor)
            appEvents.editorSettingsChanged.send(())
            syncTracker.markDirty(.settings, id: AppSettingsCategory.editor)
        }
    }

    @Published var formatter: SQLFormatterSettings {
        didSet {
            guard formatter != oldValue else { return }
            storage.saveFormatter(formatter)
            syncTracker.markDirty(.settings, id: AppSettingsCategory.formatter)
        }
    }

    var formatterOptions: SQLFormatterOptions {
        formatter.options(for: editor)
    }

    // Device-local, absent from `AppSettingsCategory.synced`: a zoom press never pushes a record an older build could reset.
    @Published var typography: TypographySettings {
        didSet {
            guard typography != oldValue else { return }
            storage.saveTypography(typography)
            themeEngine.apply(typography: typography)
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

    @Published var valueColors: ValueColorSettings {
        didSet {
            guard valueColors != oldValue else { return }
            storage.saveValueColors(valueColors)
            appEvents.valueColorSettingsChanged.send(())
            syncTracker.markDirty(.settings, id: AppSettingsCategory.valueColors)
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
            copilotService.stopIfDisallowed(by: ai)
        }
    }

    // Every writer, a reset from another pane included, has to reach the Keychain flag and the coordinator.
    @Published var sync: SyncSettings {
        didSet {
            storage.saveSync(sync)
            passwordSyncDefaults.set(sync.syncsPasswords, forKey: KeychainHelper.passwordSyncEnabledKey)
            if oldValue.enabled != sync.enabled {
                switchSync(sync.enabled)
            }
        }
    }

    @Published var mcp: MCPSettings {
        didSet {
            guard !isValidating else { return }
            var validated = mcp
            validated.port = mcp.validatedPort
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
            if enabledChanged || portChanged {
                if mcp.enabled {
                    mcpServerManager.scheduleRestart(port: UInt16(clamping: mcp.port))
                } else {
                    mcpServerManager.scheduleStop()
                }
            }
        }
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
    private let passwordSyncDefaults: UserDefaults
    private let switchSync: @MainActor (Bool) -> Void
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
        connectionListPreferences: ConnectionListPreferences = .shared,
        passwordSyncDefaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        switchSync: @escaping @MainActor (Bool) -> Void = { enabled in
            // Read at call time, so building the shared settings never builds the coordinator.
            if enabled {
                SyncCoordinator.shared.enableSync()
            } else {
                SyncCoordinator.shared.disableSync()
            }
        }
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
        self.passwordSyncDefaults = passwordSyncDefaults
        self.switchSync = switchSync

        self.general = storage.loadGeneral()
        self.appearance = storage.loadAppearance()
        self.appearanceMode = storage.loadAppearanceMode()
        self.editor = storage.loadEditor()
        self.formatter = storage.loadFormatter()
        self.dataGrid = storage.loadDataGrid()
        self.valueColors = storage.loadValueColors()
        self.history = storage.loadHistory()
        self.tabs = storage.loadTabs()
        self.keyboard = storage.loadKeyboard()
        self.ai = Self.migrateAI(storage.loadAI())
        self.sync = storage.loadSync()
        self.mcp = storage.loadMCP()
        self.notifications = storage.loadNotifications()
        self.typography = storage.loadTypography(systemIsDark: NSApp?.effectiveAppearance.isDarkTheme ?? false)

        general.language.apply()

        themeEngine.apply(typography: typography)
        themeEngine.apply(
            mode: appearanceMode,
            lightThemeId: appearance.preferredLightThemeId,
            darkThemeId: appearance.preferredDarkThemeId
        )

        dateFormattingService.updateFormat(dataGrid.dateFormat)
    }

    // Settings saved before there was an active provider would otherwise read as AI turned off.
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

    // Resets Sparkle's update preferences too: the reset alert promises every section.
    func resetToDefaults() {
        general = .default
        appearance = .default
        appearanceMode = .auto
        editor = .default
        formatter = .default
        dataGrid = .default
        valueColors = .default
        history = .default
        tabs = .default
        keyboard = .default
        ai = ai.resetKeepingProviders
        sync = .default
        mcp = .default
        typography = .default
        storage.resetToDefaults()
        InspectorFieldHeightStore.shared.reload()
        connectionListPreferences.resetShowsRecent()
        SoftwareUpdater.shared.resetUpdatePreferences()
        AppModuleActivation.resetToDefaults()
    }
}
