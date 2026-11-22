import Combine
import Foundation
@testable import TablePro
import SwiftUI
import Testing

@MainActor
private final class PublishCounter {
    private(set) var count = 0
    private var subscription: AnyCancellable?

    init(_ publisher: ObservableObjectPublisher) {
        subscription = publisher.sink { [weak self] _ in self?.count += 1 }
    }
}

@MainActor
struct SidebarTabsSettingsTests {
    @Test("The default sidebar layout is List")
    func fallbackIsList() {
        #expect(SidebarLayout.fallback == .flat)
        #expect(SharedSidebarState().sidebarLayout == .fallback)
    }

    @Test("An unset or unknown default layout reads as the fallback, a stored one as itself")
    func defaultLayoutReadsTheStoredValue() {
        let defaults = AppStorageEnvironment.shared.defaults
        let key = SidebarPersistenceKey.defaultLayout
        let saved = defaults.string(forKey: key)
        defer {
            if let saved {
                defaults.set(saved, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        #expect(SharedSidebarState.defaultLayout == .fallback)

        defaults.set("outline", forKey: key)
        #expect(SharedSidebarState.defaultLayout == .fallback)

        SharedSidebarState.defaultLayout = .tree
        #expect(defaults.string(forKey: key) == SidebarLayout.tree.rawValue)
        #expect(SharedSidebarState.defaultLayout == .tree)
    }

    @Test("A pane control is one General write, and only a sidebar field redraws the sidebar")
    func paneWritesPublishOnce() {
        let slice = SettingsSlice(GeneralSettings.default)
        let preferences = SidebarDisplayPreferences(general: slice)
        let sliceWrites = PublishCounter(slice.objectWillChange)
        let sidebarRedraws = PublishCounter(preferences.objectWillChange)
        // The same shape as the entry's `$general.value`.
        let settings = Binding(get: { slice.value }, set: { slice.value = $0 })

        settings.showObjectComments.wrappedValue.toggle()
        #expect(sliceWrites.count == 1)
        #expect(sidebarRedraws.count == 1)
        #expect(preferences.options.showObjectComments == !GeneralSettings.default.showObjectComments)

        settings.showWorkspaceRail.wrappedValue.toggle()
        #expect(sliceWrites.count == 2)
        #expect(sidebarRedraws.count == 1)

        settings.sidebarRowSize.wrappedValue = .small
        #expect(sliceWrites.count == 3)
        #expect(sidebarRedraws.count == 2)
        #expect(preferences.options.rowSize == .small)

        settings.sidebarRowSize.wrappedValue = .small
        #expect(sliceWrites.count == 3)
        #expect(sidebarRedraws.count == 2)
    }

    @Test("The preview tabs switch writes the Tabs slice")
    func previewTabsWritesTabs() {
        let slice = SettingsSlice(TabSettings.default)
        let writes = PublishCounter(slice.objectWillChange)
        let tabs = Binding(get: { slice.value }, set: { slice.value = $0 })

        tabs.enablePreviewTabs.wrappedValue.toggle()

        #expect(writes.count == 1)
        #expect(slice.value.enablePreviewTabs == !TabSettings.default.enablePreviewTabs)
    }
}
