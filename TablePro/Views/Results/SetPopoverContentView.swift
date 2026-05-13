//
//  SetPopoverContentView.swift
//  TablePro
//
//  Checkbox popover for SET column editing (multi-select).
//

import SwiftUI

struct SetPopoverContentView: View {
    let allowedValues: [String]
    let initialSelections: [String: Bool]
    let onCommit: (String?) -> Void
    let onDismiss: () -> Void

    @State private var selections: [String: Bool]

    init(
        allowedValues: [String],
        initialSelections: [String: Bool],
        onCommit: @escaping (String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.allowedValues = allowedValues
        self.initialSelections = initialSelections
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        self._selections = State(initialValue: initialSelections)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(allowedValues, id: \.self) { value in
                        Toggle(
                            value,
                            isOn: Binding(
                                get: { selections[value] ?? false },
                                set: { selections[value] = $0 }
                            )
                        )
                        .toggleStyle(.checkbox)
                        .font(.system(.callout, design: .monospaced))
                    }
                }
                .padding(12)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { commitAndDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 260)
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func commitAndDismiss() {
        let selected = allowedValues.filter { selections[$0] == true }
        let result = selected.isEmpty ? nil : selected.joined(separator: ",")
        onCommit(result)
        onDismiss()
    }
}
