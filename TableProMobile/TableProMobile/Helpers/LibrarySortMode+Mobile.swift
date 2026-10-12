import Foundation
import TableProConnectionLibrary

nonisolated extension LibrarySortMode {
    var mobileTitle: LocalizedStringResource {
        switch self {
        case .manual: LocalizedStringResource("Manual")
        case .name: LocalizedStringResource("Name")
        case .databaseType: LocalizedStringResource("Database Type")
        case .lastConnected: LocalizedStringResource("Last Connected")
        }
    }
}
