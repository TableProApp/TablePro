//
//  DateTimePickerContentView.swift
//  TablePro
//
//  Native SwiftUI date picker popover for editing date, datetime, timestamp,
//  and time columns in the data grid.
//

import SwiftUI

struct DateTimePickerContentView: View {
    let components: TemporalComponents
    let timeZone: TimeZone
    let onCommit: (Date) -> Void
    let onDismiss: () -> Void

    @State private var date: Date

    init(
        initialDate: Date,
        components: TemporalComponents,
        timeZone: TimeZone,
        onCommit: @escaping (Date) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.components = components
        self.timeZone = timeZone
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        self._date = State(initialValue: initialDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
                .labelsHidden()
                .environment(\.calendar, Calendar(identifier: .gregorian))
                .environment(\.timeZone, timeZone)
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
        .fixedSize()
    }

    @ViewBuilder
    private var picker: some View {
        switch components {
        case .dateOnly:
            DatePicker("", selection: $date, displayedComponents: [.date])
                .datePickerStyle(.graphical)
        case .timeOnly:
            DatePicker("", selection: $date, displayedComponents: [.hourMinuteAndSecond])
                .datePickerStyle(.stepperField)
        case .dateAndTime:
            DatePicker("", selection: $date, displayedComponents: [.date, .hourMinuteAndSecond])
                .datePickerStyle(.graphical)
        }
    }
}
