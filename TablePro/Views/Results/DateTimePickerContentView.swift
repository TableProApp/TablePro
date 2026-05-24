//
//  DateTimePickerContentView.swift
//  TablePro
//
//  Custom SwiftUI date picker popover for editing date, datetime, timestamp,
//  and time columns in the data grid. macOS has no native modern calendar grid,
//  so the month view and time field are built here.
//

import SwiftUI

struct DateTimePickerContentView: View {
    let components: TemporalComponents
    let onCommit: (Date) -> Void
    let onDismiss: () -> Void

    private let calendar: Calendar
    @State private var date: Date

    init(
        initialDate: Date,
        components: TemporalComponents,
        timeZone: TimeZone,
        onCommit: @escaping (Date) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.components = components
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self._date = State(initialValue: initialDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                if components != .timeOnly {
                    CalendarMonthView(date: $date, calendar: calendar)
                }
                if components != .dateOnly {
                    TimeFieldView(date: $date, calendar: calendar)
                }
            }
            .padding(12)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    onCommit(date)
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: components == .timeOnly ? 200 : 252)
    }
}

private struct CalendarMonthView: View {
    @Binding var date: Date
    let calendar: Calendar

    @State private var visibleMonth: Date

    private let cellSize: CGFloat = 30
    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 3), count: 7)
    private let monthTitleFormatter: DateFormatter
    private let dayLabelFormatter: DateFormatter

    init(date: Binding<Date>, calendar: Calendar) {
        self._date = date
        self.calendar = calendar
        self._visibleMonth = State(initialValue: date.wrappedValue)
        self.monthTitleFormatter = Self.makeFormatter(calendar: calendar) { $0.dateFormat = "MMMM yyyy" }
        self.dayLabelFormatter = Self.makeFormatter(calendar: calendar) {
            $0.dateStyle = .long
            $0.timeStyle = .none
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            header
            if let month = CalendarMonth(containing: visibleMonth, calendar: calendar) {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(Array(month.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: cellSize, height: 18)
                    }
                    ForEach(Array(month.days.enumerated()), id: \.offset) { _, day in
                        dayCell(day)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)

            Spacer()

            Text(monthTitleFormatter.string(from: visibleMonth))
                .font(.headline)

            Spacer()

            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Date?) -> some View {
        if let day {
            let isSelected = calendar.isDate(day, inSameDayAs: date)
            let isToday = calendar.isDateInToday(day)
            Button {
                select(day)
            } label: {
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout)
                    .frame(width: cellSize, height: cellSize)
                    .background {
                        if isSelected {
                            Circle().fill(Color.accentColor)
                        } else if isToday {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 1)
                        }
                    }
                    .foregroundStyle(dayColor(isSelected: isSelected, isToday: isToday))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dayLabelFormatter.string(from: day))
        } else {
            Color.clear.frame(width: cellSize, height: cellSize)
        }
    }

    private func dayColor(isSelected: Bool, isToday: Bool) -> Color {
        if isSelected { return .white }
        if isToday { return .accentColor }
        return .primary
    }

    private func shiftMonth(_ delta: Int) {
        if let month = calendar.date(byAdding: .month, value: delta, to: visibleMonth) {
            visibleMonth = month
        }
    }

    private func select(_ day: Date) {
        var dayComponents = calendar.dateComponents([.year, .month, .day], from: day)
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        dayComponents.hour = time.hour
        dayComponents.minute = time.minute
        dayComponents.second = time.second
        if let newDate = calendar.date(from: dayComponents) {
            date = newDate
        }
    }

    private static func makeFormatter(calendar: Calendar, configure: (DateFormatter) -> Void) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        configure(formatter)
        return formatter
    }
}

private struct TimeFieldView: View {
    @Binding var date: Date
    let calendar: Calendar

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumIntegerDigits = 2
        formatter.maximumFractionDigits = 0
        formatter.allowsFloats = false
        return formatter
    }()

    var body: some View {
        HStack(spacing: 6) {
            field(for: .hour, range: 0...23)
            separator
            field(for: .minute, range: 0...59)
            separator
            field(for: .second, range: 0...59)
        }
    }

    private var separator: some View {
        Text(":").foregroundStyle(.secondary)
    }

    private func field(for unit: Calendar.Component, range: ClosedRange<Int>) -> some View {
        let binding = Binding(
            get: { calendar.component(unit, from: date) },
            set: { set(unit, to: min(range.upperBound, max(range.lowerBound, $0))) }
        )
        return HStack(spacing: 1) {
            TextField("", value: binding, formatter: Self.formatter)
                .frame(width: 26)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
            Stepper("", value: binding, in: range)
                .labelsHidden()
        }
    }

    private func set(_ unit: Calendar.Component, to value: Int) {
        var dateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        switch unit {
        case .hour: dateComponents.hour = value
        case .minute: dateComponents.minute = value
        case .second: dateComponents.second = value
        default: break
        }
        if let newDate = calendar.date(from: dateComponents) {
            date = newDate
        }
    }
}
