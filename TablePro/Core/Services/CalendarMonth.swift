//
//  CalendarMonth.swift
//  TablePro
//
//  Month grid layout for the data grid's date picker: leading blank cells,
//  the days of the month, and weekday header symbols ordered by the calendar's
//  first weekday.
//

import Foundation

struct CalendarMonth: Equatable {
    let leadingBlanks: Int
    let dayCount: Int
    let days: [Date?]
    let weekdaySymbols: [String]

    init?(containing date: Date, calendar: Calendar) {
        guard let monthInterval = calendar.dateInterval(of: .month, for: date),
              let dayCount = calendar.range(of: .day, in: .month, for: date)?.count else {
            return nil
        }

        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        let leadingBlanks = (firstWeekday - calendar.firstWeekday + 7) % 7

        var days: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for offset in 0..<dayCount {
            days.append(calendar.date(byAdding: .day, value: offset, to: monthInterval.start))
        }

        let symbols = calendar.veryShortWeekdaySymbols
        let symbolOffset = calendar.firstWeekday - 1

        self.leadingBlanks = leadingBlanks
        self.dayCount = dayCount
        self.days = days
        self.weekdaySymbols = Array(symbols[symbolOffset...] + symbols[..<symbolOffset])
    }
}
