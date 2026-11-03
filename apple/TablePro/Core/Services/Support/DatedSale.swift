//
//  DatedSale.swift
//  TablePro
//

import Foundation

/// A discount on Pro that runs between two fixed instants.
///
/// Live from `start`, and gone at `end`. Kept pure, so its boundaries are tested without a window
/// or a clock.
internal struct DatedSale: Equatable, Sendable {
    let start: Date
    let end: Date
    let percentOff: Int
    let page: URL

    func isLive(at date: Date) -> Bool {
        start <= date && date < end
    }
}

extension DatedSale {
    /// The dates are fixed in the build because this is one dated sale, not a campaign the app
    /// fetches: its notice is removed in the first release after it ends. The end is midnight
    /// Pacific time on December 1.
    static let blackFriday2026 = DatedSale(
        start: Date(timeIntervalSince1970: 1_795_478_400), // 2026-11-24 00:00:00 UTC
        end: Date(timeIntervalSince1970: 1_796_112_000), // 2026-12-01 08:00:00 UTC
        percentOff: 40,
        page: SupportLinks.blackFriday(.blackFriday)
    )
}
