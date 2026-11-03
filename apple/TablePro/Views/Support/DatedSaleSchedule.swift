//
//  DatedSaleSchedule.swift
//  TablePro
//

import SwiftUI

/// Redraws a `TimelineView` when its sale starts and when it ends, and at no other time.
///
/// Not `.explicit([sale.start, sale.end])`. Measured on macOS 27, that schedule draws its first
/// frame with its first entry as the date, so a notice would show before the sale opens, and it
/// never delivers its last entry, so the notice would stay after the sale ends. This one starts at
/// the moment the view appears and ends on a date that never comes, so every boundary arrives.
struct DatedSaleSchedule: TimelineSchedule {
    let sale: DatedSale

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> [Date] {
        [startDate] + [sale.start, sale.end].filter { $0 > startDate } + [.distantFuture]
    }
}
