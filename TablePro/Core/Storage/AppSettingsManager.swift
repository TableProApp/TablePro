import AppKit
import Combine
import Foundation
import Observation
import os
import TableProSync

@MainActor
enum AppRuntimeDependencyProviders {
    static func mcpServerManager() -> MCPServerManager {
        MCPServerManager.shared
    }

    static func copilotService() -> CopilotService {
        CopilotService.shared
    }

    static func queryHistoryManager() -> QueryHistoryManager {
        QueryHistoryManager.shared
    }

    static func historySettings() -> HistorySettings {
        AppSettingsManager.shared.history
    }

    static func mcpSettings() -> MCPSettings {
        AppSettingsManager.shared.mcp
    }

    static func aiSettings() -> AISettings {
        AppSettingsManager.shared.ai
    }
}

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
            general.language.apply(userDefaults: userDefaults)
            storage.saveGeneral(general)
            syncTracker.markDirty(.settings, id: "general")
        }
    }

    var appearance: AppearanceSettings {
        didSet {
            storage.saveAppearance(appearance)
            themeEngine.updateAppearanceAndTheme(
                mode: appearance.appearanceMode,
                lightThemeId: appearance.preferredLightThemeId,
                darkThemeId: appearance.preferredDarkThemeId
            )
            syncTracker.markDirty(.settings, id: "appearance")
        }
    }

    var editor: EditorSettings {
        didSet {
            storage.saveEditor(editor)
            themeEngine.updateEditorSettings(
                highlightCurrentLine: editor.highlightCurrentLine,
                showLineNumbers: editor.showLineNumbers,
                tabWidth: editor.clampedTabWidth,

                wordWrap: editor.wordWrap
            )
            appEvents.editorSettingsChanged.send(())
            syncTracker.markDirty(.settings, id: "editor")
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
            dateFormattingService.updateFormat(validated.dateFormat)
            appEvents.dataGridSettingsChanged.send(())
            syncTracker.markDirty(.settings, id: "dataGrid")
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
            syncTracker.markDirty(.settings, id: "history")
        }
    }

    var tabs: TabSettings {
        didSet {
            storage.saveTabs(tabs)
            syncTracker.markDirty(.settings, id: "tabs")
        }
    }

    var keyboard: KeyboardSettings {
        didSet {
            storage.saveKeyboard(keyboard)
            syncTracker.markDirty(.settings, id: "keyboard")
        }
    }

    var ai: AISettings {
        didSet {
            storage.saveAI(ai)
            syncTracker.markDirty(.settings, id: "ai")
            appEvents.aiSettingsChanged.send(())
            let hadCopilot = oldValue.providers.contains(where: { $0.type == .copilot })
            let hasCopilot = ai.providers.contains(where: { $0.type == .copilot })
            if hasCopilot != hadCopilot {
                let copilotService = copilotServiceProvider()
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

    var sync: SyncSettings {
        didSet {
            passwordSyncStateStore.apply(sync)
            storage.saveSync(sync)
            syncTracker.markDirty(.settings, id: "sync")
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
            syncTracker.markDirty(.settings, id: "mcp")
            let enabledChanged = mcp.enabled != oldValue.enabled
            let portChanged = mcp.port != oldValue.port
            let remoteChanged = mcp.allowRemoteConnections != oldValue.allowRemoteConnections
            let authChanged = mcp.requireAuthentication != oldValue.requireAuthentication
            if enabledChanged || portChanged || remoteChanged || authChanged {
                let mcpServerManager = mcpServerManagerProvider()
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

        let mcpServerManager = mcpServerManagerProvider()
        let tokenStore = mcpServerManager.tokenStore ?? MCPTokenStore()
        if mcpServerManager.tokenStore == nil {
            await tokenStore.loadFromDisk()
        }
        let existing = await tokenStore.list().filter { $0.name != MCPTokenStore.stdioBridgeTokenName }
        guard existing.isEmpty else {
            mcp.requireAuthentication = value
            return nil
        }

        let defaultName = String(localized: "Default token")
        let result = await tokenStore.generate(name: defaultName, permissions: .fullAccess)
        mcp.requireAuthentication = value
        return result
    }

    @ObservationIgnored private let storage: AppSettingsStorage
    @ObservationIgnored private let themeEngine: ThemeEngine
    @ObservationIgnored private let syncTracker: DesktopSyncChangeTracker
    @ObservationIgnored private let appEvents: AppEvents
    @ObservationIgnored private let dateFormattingService: DateFormattingService
    @ObservationIgnored private let queryHistoryManagerProvider: @MainActor () -> QueryHistoryManager
    @ObservationIgnored private let mcpServerManagerProvider: @MainActor () -> MCPServerManager
    @ObservationIgnored private let copilotServiceProvider: @MainActor () -> CopilotService
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let passwordSyncStateStore: PasswordSyncStateStore
    @ObservationIgnored private var isValidating = false
    @ObservationIgnored private var accessibilityTextSizeObserver: NSObjectProtocol?
    @ObservationIgnored private var lastAccessibilityScale: CGFloat = 1.0

    convenience init() {
        self.init(
            storage: .shared,
            themeEngine: .shared,
            syncTracker: .shared,
            appEvents: .shared,
            dateFormattingService: .shared,
            queryHistoryManagerProvider: AppRuntimeDependencyProviders.queryHistoryManager,
            mcpServerManagerProvider: AppRuntimeDependencyProviders.mcpServerManager,
            copilotServiceProvider: AppRuntimeDependencyProviders.copilotService,
            userDefaults: .standard,
            passwordSyncStateStore: .shared
        )
    }

    init(
        storage: AppSettingsStorage,
        themeEngine: ThemeEngine,
        syncTracker: DesktopSyncChangeTracker,
        appEvents: AppEvents,
        dateFormattingService: DateFormattingService,
        queryHistoryManagerProvider: @escaping @MainActor () -> QueryHistoryManager,
        mcpServerManagerProvider: @escaping @MainActor () -> MCPServerManager,
        copilotServiceProvider: @escaping @MainActor () -> CopilotService,
        userDefaults: UserDefaults,
        passwordSyncStateStore: PasswordSyncStateStore
    ) {
        self.storage = storage
        self.themeEngine = themeEngine
        self.syncTracker = syncTracker
        self.appEvents = appEvents
        self.dateFormattingService = dateFormattingService
        self.queryHistoryManagerProvider = queryHistoryManagerProvider
        self.mcpServerManagerProvider = mcpServerManagerProvider
        self.copilotServiceProvider = copilotServiceProvider
        self.userDefaults = userDefaults
        self.passwordSyncStateStore = passwordSyncStateStore

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

        general.language.apply(userDefaults: userDefaults)
        passwordSyncStateStore.apply(sync)

        themeEngine.updateAppearanceAndTheme(
            mode: appearance.appearanceMode,
            lightThemeId: appearance.preferredLightThemeId,
            darkThemeId: appearance.preferredDarkThemeId
        )

        themeEngine.updateEditorSettings(
            highlightCurrentLine: editor.highlightCurrentLine,
            showLineNumbers: editor.showLineNumbers,
            tabWidth: editor.clampedTabWidth,
            wordWrap: editor.wordWrap
        )

        dateFormattingService.updateFormat(dataGrid.dateFormat)

        observeAccessibilityTextSizeChanges()

        if ai.enabled, ai.providers.contains(where: { $0.type == .copilot }) {
            let copilotServiceProvider = self.copilotServiceProvider
            Task { @MainActor in await copilotServiceProvider().start() }
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
                themeEngine.reloadFontCaches()
                appEvents.accessibilityTextSizeChanged.send(())
            }
        }
    }

    private func applyHistorySettingsImmediately() async {
        await queryHistoryManagerProvider().applySettingsChange()
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
        mcp = .default
        storage.resetToDefaults()
    }
}
