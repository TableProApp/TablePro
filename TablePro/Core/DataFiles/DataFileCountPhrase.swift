//
//  DataFileCountPhrase.swift
//  TablePro
//

import Foundation

enum DataFileCountPhrase {
    static func rows(_ count: Int) -> String {
        count == 1 ? String(localized: "1 row") : String(format: String(localized: "%@ rows"), count.formatted())
    }

    static func visibleRows(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 visible row")
            : String(format: String(localized: "%@ visible rows"), count.formatted())
    }

    static func cells(_ count: Int) -> String {
        count == 1 ? String(localized: "1 cell") : String(format: String(localized: "%@ cells"), count.formatted())
    }

    static func matches(_ count: Int) -> String {
        count == 1 ? String(localized: "1 match") : String(format: String(localized: "%@ matches"), count.formatted())
    }

    static func duplicateRows(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 duplicate row")
            : String(format: String(localized: "%@ duplicate rows"), count.formatted())
    }

    static func raggedRows(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 row has a different number of fields")
            : String(format: String(localized: "%@ rows have a different number of fields"), count.formatted())
    }
}
