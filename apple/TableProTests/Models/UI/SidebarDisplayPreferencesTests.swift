import Combine
import Foundation
@testable import TablePro
import Testing

@MainActor
private final class WillChangeCounter {
    private(set) var count = 0
    private var subscription: AnyCancellable?

    init(_ publisher: ObservableObjectPublisher) {
        subscription = publisher.sink { [weak self] _ in self?.count += 1 }
    }
}

@MainActor
struct SidebarDisplayPreferencesTests {
    @Test("Starts from the slice's current value")
    func seedsFromSlice() {
        var general = GeneralSettings.default
        general.sidebarRowSize = .large
        general.showSystemContainers = true
        general.showObjectComments = false
        let preferences = SidebarDisplayPreferences(general: SettingsSlice(general))

        #expect(preferences.options.rowSize == .large)
        #expect(preferences.options.showSystemContainers)
        #expect(!preferences.options.showObjectComments)
        #expect(preferences.options.showObjectIcons)
    }

    @Test("A General write the sidebar does not draw publishes nothing")
    func unrelatedWriteIsSilent() {
        let slice = SettingsSlice(GeneralSettings.default)
        let preferences = SidebarDisplayPreferences(general: slice)
        let counter = WillChangeCounter(preferences.objectWillChange)

        slice.update {
            $0.queryTimeoutSeconds = 120
            $0.shareAnalytics = false
            $0.showWorkspaceRail = false
        }

        #expect(counter.count == 0)
        #expect(preferences.options == SidebarDisplayOptions(GeneralSettings.default))
    }

    @Test("One write of two sidebar fields publishes once, with both values")
    func sidebarWritePublishesOnce() {
        let slice = SettingsSlice(GeneralSettings.default)
        let preferences = SidebarDisplayPreferences(general: slice)
        let counter = WillChangeCounter(preferences.objectWillChange)

        slice.update {
            $0.showObjectIcons = false
            $0.showObjectComments = false
        }

        #expect(counter.count == 1)
        #expect(!preferences.options.showObjectIcons)
        #expect(!preferences.options.showObjectComments)
    }

    @Test("Each listing field reaches the options")
    func everyListingFieldIsCarried() {
        let slice = SettingsSlice(GeneralSettings.default)
        let preferences = SidebarDisplayPreferences(general: slice)
        let counter = WillChangeCounter(preferences.objectWillChange)

        slice.update { $0.showRecentTables.toggle() }
        slice.update { $0.showSystemContainers.toggle() }
        slice.update { $0.showPartitions.toggle() }

        let expected = SidebarDisplayOptions(slice.value)
        #expect(counter.count == 3)
        #expect(preferences.options == expected)
    }

    @Test("A row size change publishes")
    func rowSizeChangePublishes() {
        let slice = SettingsSlice(GeneralSettings.default)
        let preferences = SidebarDisplayPreferences(general: slice)
        let counter = WillChangeCounter(preferences.objectWillChange)

        slice.update { $0.sidebarRowSize = .small }

        #expect(counter.count == 1)
        #expect(preferences.options.rowSize == .small)
    }
}
