import AppKit
import Combine
import Foundation
import TableProSyncTransport

@MainActor
final class AppSettingsManager {
    static let shared = AppSettingsManager()

    let generalSlice: SettingsSlice<GeneralSettings>
    let appearanceSlice: SettingsSlice<AppearanceSettings>
    // Device-local, like typography: each Mac picks Auto, Light or Dark for itself.
    let appearanceModeSlice: SettingsSlice<AppAppearanceMode>
    let editorSlice: SettingsSlice<EditorSettings>
    let formatterSlice: SettingsSlice<SQLFormatterSettings>
    // Device-local, absent from `AppSettingsCategory.synced`: a zoom press never pushes a record an older build could reset.
    let typographySlice: SettingsSlice<TypographySettings>
    let notificationsSlice: SettingsSlice<NotificationSettings>
    let dataGridSlice: SettingsSlice<DataGridSettings>
    let valueColorsSlice: SettingsSlice<ValueColorSettings>
    let historySlice: SettingsSlice<HistorySettings>
    let tabsSlice: SettingsSlice<TabSettings>
    let keyboardSlice: SettingsSlice<KeyboardSettings>
    let aiSlice: SettingsSlice<AISettings>
    let syncSlice: SettingsSlice<SyncSettings>
    let mcpSlice: SettingsSlice<MCPSettings>

    var general: GeneralSettings {
        get { generalSlice.value }
        set { generalSlice.value = newValue }
    }

    var appearance: AppearanceSettings {
        get { appearanceSlice.value }
        set { appearanceSlice.value = newValue }
    }

    var appearanceMode: AppAppearanceMode {
        get { appearanceModeSlice.value }
        set { appearanceModeSlice.value = newValue }
    }

    var editor: EditorSettings {
        get { editorSlice.value }
        set { editorSlice.value = newValue }
    }

    var formatter: SQLFormatterSettings {
        get { formatterSlice.value }
        set { formatterSlice.value = newValue }
    }

    var formatterOptions: SQLFormatterOptions {
        formatter.options(for: editor)
    }

    var typography: TypographySettings {
        get { typographySlice.value }
        set { typographySlice.value = newValue }
    }

    var notifications: NotificationSettings {
        get { notificationsSlice.value }
        set { notificationsSlice.value = newValue }
    }

    var dataGrid: DataGridSettings {
        get { dataGridSlice.value }
        set { dataGridSlice.value = newValue }
    }

    var valueColors: ValueColorSettings {
        get { valueColorsSlice.value }
        set { valueColorsSlice.value = newValue }
    }

    var history: HistorySettings {
        get { historySlice.value }
        set { historySlice.value = newValue }
    }

    var tabs: TabSettings {
        get { tabsSlice.value }
        set { tabsSlice.value = newValue }
    }

    var keyboard: KeyboardSettings {
        get { keyboardSlice.value }
        set { keyboardSlice.value = newValue }
    }

    var ai: AISettings {
        get { aiSlice.value }
        set { aiSlice.value = newValue }
    }

    var sync: SyncSettings {
        get { syncSlice.value }
        set { syncSlice.value = newValue }
    }

    var mcp: MCPSettings {
        get { mcpSlice.value }
        set { mcpSlice.value = newValue }
    }

    private let storage: AppSettingsStorage
    private let themeEngine: ThemeEngine
    private let syncJournal: SyncHostJournal
    private let appEvents: AppEvents
    private let dateFormattingService: DateFormattingService
    private let mcpServerManager: MCPServerManager
    private let copilotService: CopilotService
    private let connectionListPreferences: ConnectionListPreferences
    private let passwordSyncDefaults: UserDefaults
    private let switchSync: @MainActor (Bool) -> Void
    private let changeSyncCategories: @MainActor () -> Void
    private let applyHistoryRetention: @MainActor () -> Void
    private let resetOutsideSettings: @MainActor () -> Void
    private var deferredWrittenCategories: [String]?

    init(
        storage: AppSettingsStorage = .shared,
        themeEngine: ThemeEngine = .shared,
        syncJournal: SyncHostJournal = .shared,
        appEvents: AppEvents = .shared,
        dateFormattingService: DateFormattingService = .shared,
        mcpServerManager: MCPServerManager = .shared,
        copilotService: CopilotService = .shared,
        connectionListPreferences: ConnectionListPreferences = .shared,
        passwordSyncDefaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        switchSync: @escaping @MainActor (Bool) -> Void = { enabled in
            // Read at call time, so building the shared settings never builds the coordinator.
            if enabled {
                SyncProviderCoordinator.shared.enableSync()
            } else {
                SyncProviderCoordinator.shared.disableSync()
            }
        },
        changeSyncCategories: @escaping @MainActor () -> Void = {
            SyncProviderCoordinator.shared.categoriesChanged()
        },
        applyHistoryRetention: @escaping @MainActor () -> Void = {
            Task { await QueryHistoryManager.shared.applySettingsChange() }
        },
        resetOutsideSettings: @escaping @MainActor () -> Void = {
            InspectorFieldHeightStore.shared.reload()
            // The reset alert promises every section, so Sparkle's update preferences go too.
            SoftwareUpdater.shared.resetUpdatePreferences()
            AppModuleActivation.resetToDefaults()
            FilterSettingsStorage.shared.resetSettings()
        }
    ) {
        self.storage = storage
        self.themeEngine = themeEngine
        self.syncJournal = syncJournal
        self.appEvents = appEvents
        self.dateFormattingService = dateFormattingService
        self.mcpServerManager = mcpServerManager
        self.copilotService = copilotService
        self.connectionListPreferences = connectionListPreferences
        self.passwordSyncDefaults = passwordSyncDefaults
        self.switchSync = switchSync
        self.changeSyncCategories = changeSyncCategories
        self.applyHistoryRetention = applyHistoryRetention
        self.resetOutsideSettings = resetOutsideSettings

        generalSlice = SettingsSlice(storage.loadGeneral())
        appearanceSlice = SettingsSlice(storage.loadAppearance())
        appearanceModeSlice = SettingsSlice(storage.loadAppearanceMode())
        editorSlice = SettingsSlice(storage.loadEditor())
        formatterSlice = SettingsSlice(storage.loadFormatter())
        dataGridSlice = SettingsSlice(storage.loadDataGrid(), normalize: { $0.normalized })
        valueColorsSlice = SettingsSlice(storage.loadValueColors())
        historySlice = SettingsSlice(storage.loadHistory(), normalize: { $0.normalized })
        tabsSlice = SettingsSlice(storage.loadTabs())
        keyboardSlice = SettingsSlice(storage.loadKeyboard())
        aiSlice = SettingsSlice(Self.migrateAI(storage.loadAI()))
        syncSlice = SettingsSlice(storage.loadSync())
        mcpSlice = SettingsSlice(storage.loadMCP(), normalize: { $0.normalized })
        notificationsSlice = SettingsSlice(storage.loadNotifications(), normalize: { $0.normalized })
        typographySlice = SettingsSlice(
            storage.loadTypography(systemIsDark: NSApp?.effectiveAppearance.isDarkTheme ?? false)
        )

        Self.apply(generalSlice.value.language)

        themeEngine.apply(typography: typographySlice.value)
        themeEngine.apply(
            mode: appearanceModeSlice.value,
            lightThemeId: appearanceSlice.value.preferredLightThemeId,
            darkThemeId: appearanceSlice.value.preferredDarkThemeId
        )

        dateFormattingService.updateFormat(dataGridSlice.value.dateFormat)

        attachCommits()
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

    func resetToDefaults() {
        var resetGeneral = GeneralSettings.default
        // Share usage data is a consent choice, so a reset keeps it.
        resetGeneral.shareAnalytics = general.shareAnalytics

        deferredWrittenCategories = []
        general = resetGeneral
        appearance = .default
        appearanceMode = .auto
        editor = .default
        formatter = .default
        notifications = .default
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
        let changedCategories = deferredWrittenCategories ?? []
        deferredWrittenCategories = nil
        syncJournal.recorded(.settings, written: changedCategories)

        connectionListPreferences.resetShowsRecent()
        resetOutsideSettings()
    }

    private func attachCommits() {
        generalSlice.attach { [weak self] old, new in self?.commitGeneral(from: old, to: new) }
        appearanceSlice.attach { [weak self] _, new in self?.commitAppearance(new) }
        appearanceModeSlice.attach { [weak self] _, new in self?.commitAppearanceMode(new) }
        editorSlice.attach { [weak self] _, new in self?.commitEditor(new) }
        formatterSlice.attach { [weak self] _, new in self?.commitFormatter(new) }
        typographySlice.attach { [weak self] _, new in self?.commitTypography(new) }
        notificationsSlice.attach { [weak self] _, new in self?.commitNotifications(new) }
        dataGridSlice.attach { [weak self] old, new in self?.commitDataGrid(from: old, to: new) }
        valueColorsSlice.attach { [weak self] _, new in self?.commitValueColors(new) }
        historySlice.attach { [weak self] old, new in self?.commitHistory(from: old, to: new) }
        tabsSlice.attach { [weak self] _, new in self?.commitTabs(new) }
        keyboardSlice.attach { [weak self] _, new in self?.commitKeyboard(new) }
        aiSlice.attach { [weak self] _, new in self?.commitAI(new) }
        syncSlice.attach { [weak self] old, new in self?.commitSync(from: old, to: new) }
        mcpSlice.attach { [weak self] old, new in self?.commitMCP(from: old, to: new) }
    }

    // A reset collects its categories and journals them once, after the whole reset is saved.
    private func recordWritten(_ category: String) {
        if deferredWrittenCategories != nil {
            deferredWrittenCategories?.append(category)
        } else {
            syncJournal.recorded(.settings, written: [category])
        }
    }

    // AppleLanguages lives in the standard domain, which a device profile shares with the real store.
    private static func apply(_ language: AppLanguage) {
        guard AppStorageEnvironment.shared.deviceProfile == nil else { return }
        language.apply()
    }

    private func commitGeneral(from old: GeneralSettings, to new: GeneralSettings) {
        storage.saveGeneral(new)
        if old.language != new.language {
            Self.apply(new.language)
        }
        if old.showWorkspaceRail != new.showWorkspaceRail {
            appEvents.workspaceRailVisibilityChanged.send(())
        }
        if old.connectionHealthCheck != new.connectionHealthCheck {
            appEvents.connectionHealthCheckChanged.send(())
        }
        recordWritten(AppSettingsCategory.general)
    }

    private func commitAppearance(_ new: AppearanceSettings) {
        storage.saveAppearance(new)
        themeEngine.select(lightThemeId: new.preferredLightThemeId, darkThemeId: new.preferredDarkThemeId)
        recordWritten(AppSettingsCategory.appearance)
    }

    private func commitAppearanceMode(_ new: AppAppearanceMode) {
        storage.saveAppearanceMode(new)
        themeEngine.apply(mode: new)
    }

    private func commitEditor(_ new: EditorSettings) {
        storage.saveEditor(new)
        appEvents.editorSettingsChanged.send(())
        recordWritten(AppSettingsCategory.editor)
    }

    private func commitFormatter(_ new: SQLFormatterSettings) {
        storage.saveFormatter(new)
        recordWritten(AppSettingsCategory.formatter)
    }

    private func commitTypography(_ new: TypographySettings) {
        storage.saveTypography(new)
        themeEngine.apply(typography: new)
    }

    private func commitNotifications(_ new: NotificationSettings) {
        storage.saveNotifications(new)
        recordWritten(AppSettingsCategory.notifications)
    }

    private func commitDataGrid(from old: DataGridSettings, to new: DataGridSettings) {
        storage.saveDataGrid(new)
        if old.dateFormat != new.dateFormat {
            dateFormattingService.updateFormat(new.dateFormat)
        }
        appEvents.dataGridSettingsChanged.send(())
        recordWritten(AppSettingsCategory.dataGrid)
    }

    private func commitValueColors(_ new: ValueColorSettings) {
        storage.saveValueColors(new)
        appEvents.valueColorSettingsChanged.send(())
        recordWritten(AppSettingsCategory.valueColors)
    }

    private func commitHistory(from old: HistorySettings, to new: HistorySettings) {
        storage.saveHistory(new)
        if !new.hasSameRetention(as: old) {
            applyHistoryRetention()
        }
        recordWritten(AppSettingsCategory.history)
    }

    private func commitTabs(_ new: TabSettings) {
        storage.saveTabs(new)
        recordWritten(AppSettingsCategory.tabs)
    }

    private func commitKeyboard(_ new: KeyboardSettings) {
        storage.saveKeyboard(new)
        recordWritten(AppSettingsCategory.keyboard)
        MainMenuBuilder.syncKeyEquivalents(keyboard: new)
        appEvents.keyboardSettingsChanged.send(())
    }

    private func commitAI(_ new: AISettings) {
        storage.saveAI(new)
        recordWritten(AppSettingsCategory.ai)
        appEvents.aiSettingsChanged.send(())
        copilotService.stopIfDisallowed(by: new)
    }

    // Every writer, a reset from another pane included, has to reach the Keychain flag and the coordinator.
    private func commitSync(from old: SyncSettings, to new: SyncSettings) {
        storage.saveSync(new)
        passwordSyncDefaults.set(new.syncsPasswords, forKey: KeychainHelper.passwordSyncEnabledKey)
        if old.enabled != new.enabled {
            switchSync(new.enabled)
        } else if old != new {
            changeSyncCategories()
        }
    }

    private func commitMCP(from old: MCPSettings, to new: MCPSettings) {
        storage.saveMCP(new)
        guard old.enabled != new.enabled || old.port != new.port else { return }
        if new.enabled {
            mcpServerManager.scheduleRestart(port: UInt16(clamping: new.port))
        } else {
            mcpServerManager.scheduleStop()
        }
    }
}

extension HistorySettings {
    // Data Rewind's switch is not retention, so turning it never starts a cleanup.
    func hasSameRetention(as other: HistorySettings) -> Bool {
        maxEntries == other.maxEntries && maxDays == other.maxDays && autoCleanup == other.autoCleanup
    }
}

private extension NotificationSettings {
    var normalized: NotificationSettings {
        var settings = self
        settings.thresholdSeconds = validatedThresholdSeconds
        return settings
    }
}

private extension DataGridSettings {
    var normalized: DataGridSettings {
        var settings = self
        settings.nullDisplay = validatedNullDisplay
        settings.defaultPageSize = validatedDefaultPageSize
        return settings
    }
}

private extension HistorySettings {
    var normalized: HistorySettings {
        var settings = self
        settings.maxEntries = validatedMaxEntries
        settings.maxDays = validatedMaxDays
        return settings
    }
}

private extension MCPSettings {
    var normalized: MCPSettings {
        var settings = self
        settings.port = validatedPort
        settings.maxRowLimit = validatedMaxRowLimit
        settings.defaultRowLimit = validatedDefaultRowLimit
        settings.queryTimeoutSeconds = validatedQueryTimeoutSeconds
        return settings
    }
}
