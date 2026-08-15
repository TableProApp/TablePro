import Foundation

enum HistoryDateRange: String, Codable, CaseIterable, Sendable, Identifiable {
    case lastHour
    case today
    case week
    case month
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastHour: return String(localized: "Last Hour")
        case .today: return String(localized: "Today")
        case .week: return String(localized: "Last 7 Days")
        case .month: return String(localized: "Last 4 Weeks")
        case .all: return String(localized: "All Time")
        }
    }

    func since(from reference: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .lastHour: return calendar.date(byAdding: .hour, value: -1, to: reference)
        case .today: return calendar.startOfDay(for: reference)
        case .week: return calendar.date(byAdding: .day, value: -7, to: reference)
        case .month: return calendar.date(byAdding: .day, value: -28, to: reference)
        case .all: return nil
        }
    }
}
