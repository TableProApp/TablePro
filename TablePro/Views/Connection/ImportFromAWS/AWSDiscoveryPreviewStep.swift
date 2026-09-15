import SwiftUI
import TableProImport

struct AWSDiscoveryPreviewStep: View {
    let preview: ConnectionImportPreview
    let notice: String?
    let deselectedHosts: Set<String>
    let onBack: () -> Void
    var onImported: ((Int) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIds: Set<UUID> = []
    @State private var duplicateResolutions: [UUID: ImportResolution] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            if let notice {
                noticeBanner(notice)
            }
            Divider()
            ConnectionImportPreviewList(
                items: preview.items,
                allowsReplace: false,
                selectedIds: $selectedIds,
                duplicateResolutions: $duplicateResolutions
            )
            Divider()
            footer
        }
        .onAppear { selectReadyItems() }
    }

    private var header: some View {
        HStack {
            Text("Databases found in AWS")
                .font(.body.weight(.semibold))
            Spacer()
            Toggle(String(localized: "Select All"), isOn: Binding(
                get: { selectedIds.count == preview.items.count && !preview.items.isEmpty },
                set: { newValue in
                    if newValue {
                        selectedIds = Set(preview.items.map(\.id))
                    } else {
                        selectedIds.removeAll()
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    private func noticeBanner(_ notice: String) -> some View {
        Label {
            Text(verbatim: notice)
                .font(.caption)
                .lineLimit(3)
                .help(notice)
        } icon: {
            Image(systemName: "info.circle")
                .foregroundStyle(.orange)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }

    private var footer: some View {
        HStack {
            Button(String(localized: "Back")) { onBack() }

            Text("\(selectedIds.count) of \(preview.items.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(String(localized: "Import")) { performImport() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIds.isEmpty)
        }
        .padding(12)
    }

    private func selectReadyItems() {
        let ready = preview.items.filter {
            $0.status.isSelectedByDefault
                && !deselectedHosts.contains($0.connection.host.lowercased())
        }
        selectedIds.formUnion(ready.map(\.id))
    }

    private func performImport() {
        let importedCount = ConnectionImportCommit.perform(
            preview: preview,
            selectedIds: selectedIds,
            duplicateResolutions: duplicateResolutions
        )
        dismiss()
        onImported?(importedCount)
    }
}
