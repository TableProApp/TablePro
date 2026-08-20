//
//  NumberEntryPopover.swift
//  TablePro
//

import SwiftUI

/// A bounded number field that says why it will not accept what you typed.
///
/// Both of these popovers used to parse with `Int(_: String)`, which rejects the grouping separator
/// the button above them displays, so typing back the number the user could see closed the popover
/// and changed nothing. Out-of-range input was discarded the same silent way.
struct NumberEntryPopover: View {
    let caption: String
    @Binding var value: Int?
    let minimum: Int
    /// Nil when there is no trustworthy ceiling, which is what a driver's row-count estimate leaves.
    let maximum: Int?
    let fieldWidth: CGFloat
    let isFocused: FocusState<Bool>.Binding
    let fieldAccessibilityLabel: String
    let buttonTitle: String
    let onSubmit: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("", value: $value, format: .number.grouping(.never))
                    .frame(width: fieldWidth)
                    .multilineTextAlignment(.trailing)
                    .focused(isFocused)
                    .onSubmit(submit)
                    .accessibilityLabel(fieldAccessibilityLabel)
                Button(buttonTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            Text(rangeHint)
                .font(.caption2)
                .foregroundStyle(isValid ? .secondary : Color.red)
        }
        .padding(12)
        .onAppear { isFocused.wrappedValue = true }
    }

    private var isValid: Bool {
        guard let value, value >= minimum else { return false }
        guard let maximum else { return true }
        return value <= maximum
    }

    private var rangeHint: String {
        guard let maximum else {
            return String(format: String(localized: "%@ or more"), minimum.formatted())
        }
        return String(
            format: String(localized: "Between %@ and %@"),
            minimum.formatted(),
            maximum.formatted()
        )
    }

    private func submit() {
        guard let value, isValid else { return }
        onSubmit(value)
    }
}
