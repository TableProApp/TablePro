import SwiftUI

// iOS has no combo box, so the search field both filters the account's databases and takes a typed name or UUID.
struct CloudflareD1DatabasePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    let credentials: CloudflareD1Credentials
    let list: CloudflareD1DatabaseList

    @State private var query = ""
    @State private var attempt = 0

    nonisolated private struct LoadRequest: Hashable {
        let credentials: CloudflareD1Credentials
        let attempt: Int
    }

    var body: some View {
        let shown = list.databases(matching: query)
        let typed = list.typedDatabase(in: query)
        List {
            if let typed {
                Section {
                    Button(String(format: String(localized: "Use “%@”"), typed)) { pick(typed) }
                } footer: {
                    if case .failed(let message) = list.state {
                        Text(message)
                    }
                }
            }
            if !shown.isEmpty {
                Section {
                    ForEach(shown, id: \.uuid) { database in
                        row(for: database)
                    }
                } footer: {
                    if let refreshError = list.refreshError {
                        Text(refreshError)
                    }
                }
            }
        }
        .overlay {
            placeholder(hasRows: typed != nil || !shown.isEmpty)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Name or UUID"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search, submit)
        // Keyed on the credentials, never on each keystroke in the form: every list is a request against the API quota.
        .task(id: LoadRequest(credentials: credentials, attempt: attempt)) {
            await list.load(credentials)
        }
        .refreshable {
            await list.refresh(credentials)
        }
        .navigationTitle(Text("Database"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func placeholder(hasRows: Bool) -> some View {
        if !credentials.isComplete {
            if !hasRows {
                if isQueryEmpty {
                    ContentUnavailableView(
                        "No Account",
                        systemImage: "key",
                        description: Text("Enter the Account ID and API Token to list the databases in this account.")
                    )
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        } else {
            switch list.state {
            case .idle, .loading:
                ProgressView()
            case .failed(let message):
                if !hasRows {
                    ContentUnavailableView {
                        Label("Can't Load Databases", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { attempt += 1 }
                    }
                }
            case .loaded(let databases):
                if !hasRows {
                    if databases.isEmpty, isQueryEmpty {
                        ContentUnavailableView(
                            "No Databases",
                            systemImage: "cylinder.split.1x2",
                            description: Text("No D1 databases are available to this API token.")
                        )
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
        }
    }

    private func row(for database: D1DatabaseInfo) -> some View {
        let isSelected = CloudflareD1DatabaseList.reference(selection, names: database)
        return Button {
            pick(database.name)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: database.name)
                        .foregroundStyle(Color.primary)
                    Text(verbatim: database.uuid)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var isQueryEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Return picks the database the text names, listed or not.
    private func submit() {
        if let listed = list.listedDatabase(query) {
            pick(listed.name)
        } else if let typed = list.typedDatabase(in: query) {
            pick(typed)
        }
    }

    // The name, not the UUID, is stored: the session's database switcher lists names.
    private func pick(_ database: String) {
        selection = database
        dismiss()
    }
}
