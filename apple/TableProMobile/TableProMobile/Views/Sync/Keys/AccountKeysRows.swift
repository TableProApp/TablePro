import SwiftUI
import TableProFFI

// The recovery key's 14 groups, numbered so the person can type back the two the check asks for.
struct AccountRecoveryKeyGrid: View {
    let groups: [String]

    private var rows: [[(index: Int, group: String)]] {
        let numbered = groups.enumerated().map { (index: $0.offset, group: $0.element) }
        return stride(from: 0, to: numbered.count, by: 2).map { Array(numbered[$0 ..< min($0 + 2, numbered.count)]) }
    }

    var body: some View {
        Grid(horizontalSpacing: 24, verticalSpacing: 10) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row], id: \.index) { cell in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: (cell.index + 1).formatted())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(minWidth: 18, alignment: .trailing)
                            Text(verbatim: cell.group)
                                .font(.system(.title3, design: .monospaced).weight(.medium))
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
        .privacySensitive()
        .accessibilityIdentifier("account-recovery-key-grid")
    }
}

struct AccountRecoveryKeyField: View {
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        SecureField(String(localized: "Recovery Key"), text: $text, prompt: Text(verbatim: "XXXX-XXXX-XXXX-…"))
            .font(.body.monospaced())
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .submitLabel(.continue)
            .onSubmit(onSubmit)
            .accessibilityIdentifier("account-recovery-key-field")
    }
}

// The fields for the two groups the check asks for, numbered as the grid numbers them.
struct AccountRecoveryKeyTypeBack: View {
    let groups: [Int]
    @Binding var typed: [String]
    let onSubmit: () -> Void

    var body: some View {
        ForEach(groups.indices, id: \.self) { position in
            TextField(
                String(format: String(localized: "Group %@"), groups[position].formatted()),
                text: Binding(
                    get: { typed.indices.contains(position) ? typed[position] : "" },
                    set: { if typed.indices.contains(position) { typed[position] = $0 } }
                ),
                prompt: Text(verbatim: "XXXX")
            )
            .font(.body.monospaced())
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .onSubmit(onSubmit)
            .accessibilityIdentifier("account-recovery-key-group-\(position)")
        }
    }
}

struct AccountKeysStatusRow: View {
    let symbol: String
    var tint: Color = .secondary
    let title: String
    let message: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

struct AccountKeysLoadingRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .accessibilityHidden(true)
            Text(verbatim: label)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct AccountKeysFailureText: View {
    let message: String?

    var body: some View {
        if let message {
            Label {
                Text(verbatim: message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.red)
            .font(.footnote)
            .accessibilityIdentifier("account-keys-sheet-error")
        }
    }
}

// A device a rotation can keep, on for those it keeps. This device always stays.
struct AccountKeepDeviceToggle: View {
    let device: AccountDeviceInfo
    let isOn: Binding<Bool>
    let isEnabled: Bool

    private var subtitle: String {
        if device.thisDevice {
            return String(localized: "This Device")
        }
        return isEnabled
            ? String(localized: "You compared words with it")
            : String(localized: "Asks for approval again")
    }

    var body: some View {
        Toggle(isOn: isOn) {
            Text(verbatim: AccountKeysText.deviceName(device.name))
            Text(verbatim: [AccountKeysText.platform(device.platform), subtitle].compactMap { $0 }.joined(separator: " · "))
        }
        .disabled(!isEnabled)
        .accessibilityIdentifier("account-keep-device-\(device.keyDevice)")
    }
}
