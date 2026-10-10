import Foundation
import SwiftUI
import TableProImport

internal struct ImportQueryRowView: View {
    @ObservedObject var review: ImportReview
    let row: QueryRow

    var body: some View {
        let status = review.status(of: row)
        let isAvailable = status?.availability == .available
        HStack(spacing: 8) {
            Toggle(row.name, isOn: Binding(
                get: { review.status(of: row)?.isIncluded ?? false },
                set: { review.setIncluded($0, row) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isAvailable)
            .accessibilityIdentifier("import-query-\(row.ref.rawValue)")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(verbatim: row.name)
                        .font(.body)
                        .foregroundStyle(isAvailable ? HierarchicalShapeStyle.primary : .secondary)
                        .lineLimit(1)
                    if status?.availability == .alreadySaved {
                        ImportRowTag(text: String(localized: "already saved"))
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
                    if let note = Self.note(for: row, status: status) {
                        Text(verbatim: note)
                            .foregroundStyle(.orange)
                            .help(note)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .help(review.sqlPreview(of: row) ?? "")
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
