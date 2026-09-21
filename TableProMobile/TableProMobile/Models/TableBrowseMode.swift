import Foundation
import TableProDatabase

nonisolated enum TableBrowseMode: Equatable, Sendable {
    case sql
    case keyContents

    init(driver: (any DatabaseDriver)?) {
        self = Self.keyContentsReader(of: driver) == nil ? .sql : .keyContents
    }

    static func keyContentsReader(of driver: (any DatabaseDriver)?) -> (any KeyContentsBrowsing)? {
        driver as? any KeyContentsBrowsing
    }
}
