import Combine
import Foundation

struct SidebarDisplayOptions: Equatable {
    var showObjectIcons: Bool
    var showObjectComments: Bool
    var showSystemContainers: Bool
    var showRecentTables: Bool
    var showPartitions: Bool
    var rowSize: SidebarRowSizePreference

    init(_ general: GeneralSettings) {
        showObjectIcons = general.showObjectIcons
        showObjectComments = general.showObjectComments
        showSystemContainers = general.showSystemContainers
        showRecentTables = general.showRecentTables
        showPartitions = general.showPartitions
        rowSize = general.sidebarRowSize
    }
}

// Publishes only when a General field the sidebar draws changes, so a query timeout or language write leaves every sidebar alone.
@MainActor
final class SidebarDisplayPreferences: ObservableObject {
    static let shared = SidebarDisplayPreferences(general: AppSettingsManager.shared.generalSlice)

    @Published private(set) var options: SidebarDisplayOptions
    private var subscription: AnyCancellable?

    init(general: SettingsSlice<GeneralSettings>) {
        options = SidebarDisplayOptions(general.value)
        subscription = general.publisher
            .map(SidebarDisplayOptions.init)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.options = $0 }
    }
}
