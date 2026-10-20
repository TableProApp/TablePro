import SwiftUI
import TableProConnectionLibrary
import TableProImport
import TableProModels

struct SavedQueryFolderPicker: View {
    @Environment(\.dismiss) private var dismiss

    let folders: [SavedQueryFolder]
    let selection: UUID?
    let recordScope: UUID?
    let title: String
    let onPick: (UUID?) -> Void

    var body: some View {
        let rows = SavedQueryOutline.folderRows(folders)
        List {
            Section {
                destinationRow(
                    name: String(localized: "None"),
                    systemImage: "tray",
                    depth: 0,
                    folderId: nil,
                    isGlobal: false,
                    canHold: true
                )
            }
            if !rows.isEmpty {
                Section {
                    ForEach(rows) { row in
                        destinationRow(
                            name: row.folder.name,
                            systemImage: "folder",
                            depth: row.depth,
                            folderId: row.folder.id,
                            isGlobal: row.folder.connectionId == nil,
                            canHold: SavedQueryScopeRule.folder(row.folder.connectionId, canHold: recordScope)
                        )
                    }
                } footer: {
                    if SavedQueryDraft.hidesFolders(folders, forScope: recordScope) {
                        Text("Only folders available in all connections can hold a global query.")
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // A folder that cannot hold the query stays in place, dimmed, so the nesting around it still reads.
    private func destinationRow(
        name: String,
        systemImage: String,
        depth: Int,
        folderId: UUID?,
        isGlobal: Bool,
        canHold: Bool
    ) -> some View {
        let isCurrent = selection == folderId
        return Button {
            onPick(folderId)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: name)
                    .foregroundStyle(canHold ? Color.primary : Color.secondary)
                Spacer()
                if isGlobal {
                    Image(systemName: "globe")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, CGFloat(depth) * 20)
            .contentShape(Rectangle())
        }
        .disabled(!canHold)
        .accessibilityLabel(isGlobal ? name + ", " + String(localized: "global") : name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
