import SwiftUI
import TableProModels

// A file opened from another app while no connection is open: the person picks where it goes, and that connection
// opens with the import sheet over it.
struct DataImportConnectionChooser: View {
    let fileURL: URL
    let connections: [DatabaseConnection]
    let choose: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    init(fileURL: URL, connections: [DatabaseConnection], choose: @escaping (UUID) -> Void) {
        self.fileURL = fileURL
        self.connections = connections
        self.choose = choose
    }

    var body: some View {
        NavigationStack {
            Group {
                if connections.isEmpty {
                    ContentUnavailableView {
                        Label("No Connections", systemImage: "cylinder.split.1x2")
                    } description: {
                        Text("Add a connection, then open the file again.")
                    }
                } else {
                    List {
                        Section {
                            ForEach(connections) { connection in
                                Button {
                                    choose(connection.id)
                                } label: {
                                    HStack(spacing: 12) {
                                        DatabaseIconView(type: connection.type, size: 22)
                                            .frame(width: 28)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: connection.name.isEmpty ? connection.host : connection.name)
                                                .foregroundStyle(.primary)
                                            Text(verbatim: connection.type.mobileDisplayName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text(verbatim: fileURL.lastPathComponent)
                                .textCase(nil)
                        }
                    }
                }
            }
            .navigationTitle(Text("Import Into"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        discardInboxCopy()
                        dismiss()
                    }
                }
            }
        }
    }

    // Another app's "Open in" leaves its copy in the app's own Inbox, which nothing else would empty.
    private func discardInboxCopy() {
        guard ImportFileStaging.isInInbox(fileURL) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
