//
//  DateTimePickerContentView.swift
//  TablePro
//
//  Graphical calendar/clock popover for editing date, datetime, timestamp,
//  and time columns in the data grid.
//

import AppKit
import SwiftUI

struct DateTimePickerContentView: View {
    let initialDate: Date
    let elements: NSDatePicker.ElementFlags
    let timeZone: TimeZone
    let onCommit: (Date) -> Void
    let onDismiss: () -> Void

    @State private var date: Date

    init(
        initialDate: Date,
        elements: NSDatePicker.ElementFlags,
        timeZone: TimeZone,
        onCommit: @escaping (Date) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.initialDate = initialDate
        self.elements = elements
        self.timeZone = timeZone
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        self._date = State(initialValue: initialDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            GraphicalDatePicker(date: $date, elements: elements, timeZone: timeZone)
                .fixedSize()
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
}

private struct GraphicalDatePicker: NSViewRepresentable {
    @Binding var date: Date
    let elements: NSDatePicker.ElementFlags
    let timeZone: TimeZone

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerMode = .single
        picker.datePickerElements = elements
        picker.calendar = Calendar(identifier: .gregorian)
        picker.timeZone = timeZone
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.dateChanged(_:))
        picker.dateValue = date
        picker.sizeToFit()
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.date = $date
        picker.timeZone = timeZone
        if picker.dateValue != date {
            picker.dateValue = date
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(date: $date)
    }

    @MainActor
    final class Coordinator: NSObject {
        var date: Binding<Date>

        init(date: Binding<Date>) {
            self.date = date
        }

        @objc func dateChanged(_ sender: NSDatePicker) {
            date.wrappedValue = sender.dateValue
        }
    }
}
