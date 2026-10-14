@testable import TablePro
import Testing

/// Applies a settings change for one case and puts every group back after it. Only groups that
/// differ are written: each write persists, syncs and fires its observers. A user nests under
/// `GlobalStateSuites`, since the change and the case body are not one step on the main actor.
struct AppSettingsTrait: TestTrait, SuiteTrait, TestScoping {
    struct Values {
        var general: GeneralSettings
        var appearance: AppearanceSettings
        var editor: EditorSettings
        var typography: TypographySettings
        var notifications: NotificationSettings
        var dataGrid: DataGridSettings
        var history: HistorySettings
        var tabs: TabSettings
        var keyboard: KeyboardSettings
        var ai: AISettings
        var sync: SyncSettings
        var mcp: MCPSettings

        @MainActor
        init(_ manager: AppSettingsManager) {
            general = manager.general
            appearance = manager.appearance
            editor = manager.editor
            typography = manager.typography
            notifications = manager.notifications
            dataGrid = manager.dataGrid
            history = manager.history
            tabs = manager.tabs
            keyboard = manager.keyboard
            ai = manager.ai
            sync = manager.sync
            mcp = manager.mcp
        }

        @MainActor
        func write(to manager: AppSettingsManager) {
            if manager.general != general { manager.general = general }
            if manager.appearance != appearance { manager.appearance = appearance }
            if manager.editor != editor { manager.editor = editor }
            if manager.typography != typography { manager.typography = typography }
            if manager.notifications != notifications { manager.notifications = notifications }
            if manager.dataGrid != dataGrid { manager.dataGrid = dataGrid }
            if manager.history != history { manager.history = history }
            if manager.tabs != tabs { manager.tabs = tabs }
            if manager.keyboard != keyboard { manager.keyboard = keyboard }
            if manager.ai != ai { manager.ai = ai }
            if manager.sync != sync { manager.sync = sync }
            if manager.mcp != mcp { manager.mcp = mcp }
        }
    }

    let change: @Sendable (inout Values) -> Void
    var isRecursive: Bool { true }

    @MainActor
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        let manager = AppSettingsManager.shared
        let original = Values(manager)
        var changed = original
        change(&changed)
        changed.write(to: manager)
        defer { original.write(to: manager) }
        try await function()
    }
}

extension Trait where Self == AppSettingsTrait {
    /// `@Test(.appSettings { $0.dataGrid.defaultSortBehavior = .none })`
    static func appSettings(_ change: @escaping @Sendable (inout AppSettingsTrait.Values) -> Void) -> Self {
        Self(change: change)
    }
}
