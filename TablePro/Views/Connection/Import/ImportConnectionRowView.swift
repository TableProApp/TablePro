import SwiftUI
import TableProImport

internal struct ImportConnectionRowView: View {
    @ObservedObject var review: ImportReview
    let row: ConnectionRow

    var body: some View {
        let isSelected = review.isSelected(row)
        HStack(spacing: 8) {
            Toggle(row.settings.name, isOn: Binding(
                get: { review.isSelected(row) },
                set: { review.setSelected($0, row) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityIdentifier("import-connection-\(row.ref.rawValue)")

            DatabaseType(rawValue: row.settings.type).iconImage
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(verbatim: row.settings.name)
                        .font(.body)
                        .lineLimit(1)
                    if row.duplicate != nil {
                        ImportRowTag(text: String(localized: "duplicate"))
                    }
                }
                Group {
                    Text(verbatim: row.settings.displaySubtitle)
                    if let duplicate = row.duplicate {
                        Text(verbatim: String(format: String(localized: "Matches “%@”"), duplicate.name))
                    }
                    let notes = Self.notes(for: row)
                    if let note = notes.first {
                        Text(verbatim: note)
                            .foregroundStyle(.orange)
                            .help(notes.joined(separator: "\n"))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if row.duplicate != nil {
                if isSelected {
                    resolutionPicker
                }
            } else {
                statusIcon
            }
        }
        .padding(.vertical, 2)
    }

    private var resolutionPicker: some View {
        let offered = review.offeredResolutions(for: row)
        return Picker(String(localized: "If the connection is already there"), selection: Binding(
            get: { review.resolution(for: row) },
            set: { review.setResolution($0, for: row) }
        )) {
            ForEach(offered, id: \.self) { resolution in
                Text(verbatim: Self.title(for: resolution)).tag(resolution)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .labelsHidden()
        .fixedSize()
        .disabled(offered.count < 2)
        .accessibilityIdentifier("import-resolution-\(row.ref.rawValue)")
    }

    @ViewBuilder
    private var statusIcon: some View {
        if row.unsupportedTypeId != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityLabel(String(localized: "Unsupported"))
        } else if !row.warnings.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.yellow)
                .accessibilityLabel(String(localized: "Warning"))
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .accessibilityLabel(String(localized: "Ready"))
        }
    }

    static func title(for resolution: ConnectionResolution) -> String {
        switch resolution {
        case .add:
            String(localized: "Add")
        case .addCopy:
            String(localized: "As Copy")
        case .replace:
            String(localized: "Replace")
        case .keepExisting:
            String(localized: "Keep Existing, Add Queries")
        }
    }

    static func notes(for row: ConnectionRow) -> [String] {
        let unsupported = row.unsupportedTypeId.map {
            String(format: String(localized: "TablePro doesn't support “%@” connections"), $0)
        }
        return [unsupported].compactMap { $0 } + row.warnings
    }
}

internal struct ImportRowTag: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .quaternaryLabelColor))
            )
    }
}
