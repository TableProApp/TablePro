import Foundation

enum TokenExpiry: String, CaseIterable, Identifiable, Sendable {
    case never
    case oneDay
    case sevenDays
    case thirtyDays
    case sixtyDays
    case ninetyDays
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never: String(localized: "Never")
        case .oneDay: String(localized: "1 day")
        case .sevenDays: String(localized: "7 days")
        case .thirtyDays: String(localized: "30 days")
        case .sixtyDays: String(localized: "60 days")
        case .ninetyDays: String(localized: "90 days")
        case .custom: String(localized: "Custom")
        }
    }

    var days: Int? {
        switch self {
        case .never, .custom: nil
        case .oneDay: 1
        case .sevenDays: 7
        case .thirtyDays: 30
        case .sixtyDays: 60
        case .ninetyDays: 90
        }
    }

    static func defaultCustomDate(from now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 30, to: now) ?? now
    }

    func resolvedDate(custom: Date, from now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch self {
        case .never:
            nil
        case .custom:
            custom
        case .oneDay, .sevenDays, .thirtyDays, .sixtyDays, .ninetyDays:
            days.flatMap { calendar.date(byAdding: .day, value: $0, to: now) }
        }
    }
}
