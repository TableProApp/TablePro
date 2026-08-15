import Foundation

struct QueryHistoryDaySection: Identifiable, Sendable, Equatable {
    let day: Date
    let entries: [QueryHistoryEntry]

    var id: Date { day }
}

enum QueryHistoryGrouping {
    static func byDay(_ entries: [QueryHistoryEntry], calendar: Calendar = .current) -> [QueryHistoryDaySection] {
        var order: [Date] = []
        var buckets: [Date: [QueryHistoryEntry]] = [:]

        for entry in entries {
            let day = calendar.startOfDay(for: entry.executedAt)
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(entry)
        }

        return order.map { QueryHistoryDaySection(day: $0, entries: buckets[$0] ?? []) }
    }

    static func title(
        for day: Date,
        calendar: Calendar = .current,
        relativeTo reference: Date = Date()
    ) -> String {
        if calendar.isDate(day, inSameDayAs: reference) {
            return String(localized: "Today")
        }

        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: reference))
        if let yesterday, calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }

        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}
