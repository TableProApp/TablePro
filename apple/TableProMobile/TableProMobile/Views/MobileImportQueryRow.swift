import SwiftUI
import TableProImport

struct MobileImportQueryRow: View {
    let row: QueryRow
    let status: QueryStatus?
    let setIncluded: (Bool) -> Void

    var body: some View {
        let isAvailable = status?.availability == .available
        let isIncluded = status?.isIncluded ?? false
        Button {
            setIncluded(!isIncluded)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isIncluded ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: row.name)
                            .foregroundStyle(isAvailable ? Color.primary : Color.secondary)
                            .lineLimit(1)
                        if status?.availability == .alreadySaved {
                            Text("already saved")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Group {
                        Text(verbatim: row.connectionName ?? String(localized: "All connections"))
                        if let keyword = row.keyword, isAvailable, status?.droppedKeyword == nil {
                            Text(verbatim: String(format: String(localized: "Keyword “%@”"), keyword))
                        }
                        if !row.folderPath.isEmpty {
                            Text(verbatim: row.folderPath.joined(separator: " / "))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                    if let note = Self.note(for: row, status: status) {
                        Text(verbatim: note)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityAddTraits(isIncluded ? .isSelected : [])
    }

    static func note(for row: QueryRow, status: QueryStatus?) -> String? {
        guard let status else { return nil }
        switch status.availability {
        case .addedByAnotherRow:
            return String(localized: "Another selected row adds the same query.")
        case .connectionSkipped:
            return String(localized: "Its connection is not imported.")
        case .tooLarge:
            let size = ByteCountFormatter.string(fromByteCount: Int64(row.byteCount), countStyle: .file)
            return String(format: String(localized: "Too large to save (%@)"), size)
        case .alreadySaved:
            return nil
        case .available:
            break
        }
        switch status.droppedKeyword {
        case .inUse(let keyword):
            return String(format: String(localized: "Keyword “%@” is in use, so it imports without one."), keyword)
        case .invalid(let keyword):
            return String(format: String(localized: "Keyword “%@” is not valid, so it imports without one."), keyword)
        case nil:
            break
        }
        return status.nameExists ? String(localized: "A saved query with this name exists.") : nil
    }
}
