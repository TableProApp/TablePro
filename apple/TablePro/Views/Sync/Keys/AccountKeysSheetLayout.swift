//
//  AccountKeysSheetLayout.swift
//  TablePro
//

import SwiftUI

// Every key sheet: a header that says what this step does, its content, and the buttons, the default one last.
internal struct AccountKeysSheetLayout<Content: View, Auxiliary: View, Actions: View>: View {
    let title: String
    let message: String?
    let identifier: String
    @ViewBuilder let content: Content
    @ViewBuilder let auxiliary: Auxiliary
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(verbatim: message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            content

            Divider()

            DialogFooter {
                auxiliary
            } actions: {
                actions
            }
            .padding()
        }
        .frame(width: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

internal extension AccountKeysSheetLayout where Auxiliary == EmptyView {
    init(
        title: String,
        message: String?,
        identifier: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(title: title, message: message, identifier: identifier, content: content, auxiliary: { EmptyView() }, actions: actions)
    }
}

// The recovery key as 14 groups of 4, numbered, so the groups the check asks for are easy to find.
internal struct AccountRecoveryKeyGrid: View {
    let groups: [String]

    private var rows: [[(index: Int, group: String)]] {
        let numbered = groups.enumerated().map { (index: $0.offset, group: $0.element) }
        return stride(from: 0, to: numbered.count, by: 7).map { Array(numbered[$0 ..< min($0 + 7, numbered.count)]) }
    }

    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 12) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row], id: \.index) { cell in
                        VStack(spacing: 2) {
                            Text(verbatim: cell.group)
                                .font(.system(.title3, design: .monospaced).weight(.medium))
                            Text(verbatim: (cell.index + 1).formatted())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(String(
                            format: String(localized: "Group %@: %@"),
                            (cell.index + 1).formatted(),
                            cell.group.map(String.init).joined(separator: " ")
                        )))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-recovery-key-grid")
    }
}

// Where the person types or pastes the recovery key they keep. A secure field, so the key never leaves it through an
// ordinary copy that a clipboard history keeps. The core reads it with or without hyphens and spaces.
internal struct AccountRecoveryKeyField: View {
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        SecureField(String(localized: "Recovery key"), text: $text, prompt: Text(verbatim: "XXXX-XXXX-XXXX-…"))
            .font(.body.monospaced())
            .onSubmit(onSubmit)
            .accessibilityIdentifier("account-recovery-key-field")
    }
}

internal struct AccountKeysFailureNotice: View {
    let message: String?

    var body: some View {
        if let message {
            NoticeLabel(message, severity: .error)
                .accessibilityIdentifier("account-keys-sheet-error")
        }
    }
}
