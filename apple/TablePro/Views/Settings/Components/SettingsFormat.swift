import Foundation

enum SettingsFormat {
    static var ungrouped: IntegerFormatStyle<Int> { .number.grouping(.never) }

    static func duration(seconds: Int, locale: Locale = .autoupdatingCurrent) -> String {
        Duration.seconds(seconds).formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide).locale(locale)
        )
    }

    static func count(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.number.locale(locale))
    }

    // Ports and identifiers: "23508", never "23,508" or "23.508".
    static func identifier(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(ungrouped.locale(locale))
    }

    // Whole years read as "1 year" rather than "365 days".
    static func days(_ days: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        formatter.calendar = calendar
        let components: DateComponents
        if days != 0, days.isMultiple(of: 365) {
            formatter.allowedUnits = [.year]
            components = DateComponents(year: days / 365)
        } else {
            formatter.allowedUnits = [.day]
            components = DateComponents(day: days)
        }
        return formatter.string(from: components) ?? count(days, locale: locale)
    }
}
