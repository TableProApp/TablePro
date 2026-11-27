import SwiftUI
import TableProFFI
import TableProModels

// The teams this account reads and what each holds, from the connection list's More menu. A team connection opens as a
// copy in this device's library, since a connection opens from there; the copy keeps the id it was added under, so
// adding it again opens the same copy.
struct TeamLibraryView: View {
    let open: (UUID) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var showsConflicts = false
    @State private var pendingRemoval: TeamLibraryRemoval?
    @State private var pendingQueryPublish: TeamLibraryQueryPublish?
    @State private var publishOutcome: TeamLibraryPublishOutcome?
    @State private var actionFailure: TeamActionFailure?
    @State private var chosenConnection: TeamLibraryConnectionChoice?

    private var library: TeamLibraryModel {
        appState.teamLibrary
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "Team Library"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { dismiss() }
                    }
                }
                .navigationDestination(for: TeamLibraryDestinationPage.self) { page in
                    switch page {
                    case .query(let teamID, let queryID):
                        if let query = library.team(teamID)?.queries.first(where: { $0.id == queryID }) {
                            TeamQueryDetailView(query: query)
                        }
                    case .unsent:
                        TeamUnsentEditsView()
                    case .keys(let teamID):
                        if let team = library.team(teamID) {
                            TeamKeysView(model: appState.teamKeysModel(for: team))
                        }
                    }
                }
        }
        .task { await library.refresh() }
        // What was picked belongs to the sign-in it showed under.
        .onChange(of: appState.account.snapshot.sessionID) {
            chosenConnection = nil
            pendingRemoval = nil
            pendingQueryPublish = nil
        }
        .sheet(isPresented: $showsConflicts) {
            TeamConflictSheet(model: library.conflicts)
        }
        .confirmationDialog(
            pendingRemoval?.title ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { removal in
            Button(String(localized: "Remove from Team"), role: .destructive) {
                Task { await remove(removal) }
            }
        } message: { _ in
            Text("Everyone on the team loses it from their Team Library. Copies they added to their own connections stay.")
        }
        .confirmationDialog(
            String(localized: "Publish Saved Queries?"),
            isPresented: Binding(get: { pendingQueryPublish != nil }, set: { if !$0 { pendingQueryPublish = nil } }),
            titleVisibility: .visible,
            presenting: pendingQueryPublish
        ) { pending in
            Button(String(localized: "Publish")) {
                Task { await publishSavedQueries(pending) }
            }
        } message: { pending in
            Text(String(
                format: String(localized: "Every saved query and folder on this device goes to %@. Ones you published before and deleted here are removed from the team."),
                pending.team.name
            ))
        }
        .confirmationDialog(
            chosenConnection?.item.settings.name ?? "",
            isPresented: Binding(get: { chosenConnection != nil }, set: { if !$0 { chosenConnection = nil } }),
            titleVisibility: .visible,
            presenting: chosenConnection
        ) { choice in
            Button(String(localized: "Add to My Connections")) { addToMyConnections(choice) }
                .disabled(!appState.isLibraryWritable)
            if choice.team.canWrite {
                Button(String(localized: "Remove from Team"), role: .destructive) {
                    pendingRemoval = TeamLibraryRemoval(
                        team: choice.team,
                        ref: choice.item.ref,
                        name: choice.item.settings.name,
                        destination: choice.destination
                    )
                }
            }
        } message: { _ in
            Text("A copy goes into your connections, without a password. Changes the team makes later don't reach the copy.")
        }
        .alert(
            publishOutcome?.title ?? "",
            isPresented: Binding(get: { publishOutcome != nil }, set: { if !$0 { publishOutcome = nil } }),
            presenting: publishOutcome
        ) { outcome in
            if outcome.offersConflicts {
                Button(String(localized: "Review")) { showsConflicts = true }
            }
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { outcome in
            Text(outcome.message)
        }
        .alert(
            actionFailure?.title ?? "",
            isPresented: Binding(get: { actionFailure != nil }, set: { if !$0 { actionFailure = nil } }),
            presenting: actionFailure
        ) { _ in
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        .alert(
            String(localized: "Team Library Edits Deleted"),
            isPresented: Binding(
                get: { !library.discardedForAnotherOwner.isEmpty },
                set: { if !$0 { library.acknowledgeDiscarded() } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(
                format: String(localized: "Another account left these edits unsent on this device, so they were deleted: %@."),
                library.discardedForAnotherOwner.formatted(.list(type: .and))
            ))
        }
    }

    @ViewBuilder
    private var content: some View {
        if !library.isSignedIn {
            ContentUnavailableView(
                String(localized: "Sign In to Use Team Library"),
                systemImage: "person.2",
                description: Text("Sign in to your TablePro account in Settings to see the connections and saved queries your teams share.")
            )
        } else if library.teams.isEmpty {
            emptyContent
        } else {
            List {
                statusSection
                ForEach(library.teams) { team in
                    teamSection(team)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await library.refresh() }
        }
    }

    @ViewBuilder
    private var emptyContent: some View {
        if case .failed(let problem) = library.status {
            ContentUnavailableView {
                Label(String(localized: "Team Library Unavailable"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(problem.message)
            } actions: {
                Button(String(localized: "Try Again")) {
                    Task { await library.refresh() }
                }
            }
        } else {
            ContentUnavailableView(
                String(localized: "No Teams"),
                systemImage: "person.2",
                description: Text("Your account isn't on a team with a library yet.")
            )
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            TeamLibraryStatusRow(status: library.status)
            if !library.unsent.isEmpty {
                NavigationLink(value: TeamLibraryDestinationPage.unsent) {
                    LabeledContent(String(localized: "Not Sent Yet")) {
                        Text(library.unsent.count, format: .number)
                    }
                }
            }
            if !library.conflicts.conflicts.isEmpty {
                Button {
                    showsConflicts = true
                } label: {
                    LabeledContent {
                        Text(library.conflicts.conflicts.count, format: .number)
                    } label: {
                        Label(String(localized: "Resolve Conflicts"), systemImage: "exclamationmark.triangle")
                    }
                }
            }
        }
    }

    private func teamSection(_ team: TeamLibraryTeam) -> some View {
        Section {
            if team.isEmpty {
                Text("Nothing shared yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(team.connections) { item in
                Button {
                    chosenConnection = TeamLibraryConnectionChoice(team: team, item: item, destination: library.destination(team.id))
                } label: {
                    TeamLibraryConnectionRow(item: item)
                }
                .tint(.primary)
                .swipeActions(edge: .trailing) {
                    if team.canWrite {
                        Button(String(localized: "Remove"), role: .destructive) {
                            pendingRemoval = TeamLibraryRemoval(
                                team: team,
                                ref: item.ref,
                                name: item.settings.name,
                                destination: library.destination(team.id)
                            )
                        }
                    }
                }
            }
            ForEach(team.queries) { query in
                NavigationLink(value: TeamLibraryDestinationPage.query(teamID: team.id, queryID: query.id)) {
                    TeamLibraryQueryRow(query: query)
                }
                .swipeActions(edge: .trailing) {
                    if team.canWrite {
                        Button(String(localized: "Remove"), role: .destructive) {
                            pendingRemoval = TeamLibraryRemoval(
                                team: team,
                                ref: query.ref,
                                name: query.name,
                                destination: library.destination(team.id)
                            )
                        }
                    }
                }
            }
            if team.canWrite {
                Button {
                    pendingQueryPublish = TeamLibraryQueryPublish(team: team, destination: library.destination(team.id))
                } label: {
                    Label(String(localized: "Publish Saved Queries…"), systemImage: "square.and.arrow.up")
                }
                .disabled(appState.savedQueries.status != .ready)
            }
            NavigationLink(value: TeamLibraryDestinationPage.keys(teamID: team.id)) {
                Label(String(localized: "End-to-End Keys"), systemImage: "key")
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: team.name)
                if let role = team.role {
                    Spacer()
                    Text(TeamKeysPresentation.roleName(role))
                }
            }
        }
    }

    // MARK: - Actions

    private func addToMyConnections(_ choice: TeamLibraryConnectionChoice) {
        guard library.shownSessionID == choice.destination.sessionID else { return }
        guard let id = library.addToMyConnections(
            choice.item,
            of: choice.team,
            shownUnder: choice.destination.sessionID,
            in: appState
        ) else {
            actionFailure = TeamActionFailure(
                title: String(localized: "Couldn't Add the Connection"),
                message: String(localized: "Your connections couldn't be saved. Try again.")
            )
            return
        }
        dismiss()
        open(id)
    }

    // The destination is the one taken when the person picked the item, so a confirmation that outlived its sign-in
    // is refused.
    private func remove(_ removal: TeamLibraryRemoval) async {
        do throws(TeamLibraryProblem) {
            publishOutcome = TeamLibraryPublishOutcome(
                try await library.remove([removal.ref], from: removal.destination),
                action: .remove
            )
        } catch {
            publishOutcome = TeamLibraryPublishOutcome(failure: error, action: .remove)
        }
    }

    private func publishSavedQueries(_ pending: TeamLibraryQueryPublish) async {
        do throws(TeamLibraryProblem) {
            publishOutcome = TeamLibraryPublishOutcome(
                try await library.publishSavedQueries(appState.savedQueries.contents, to: pending.destination),
                action: .publish
            )
        } catch {
            publishOutcome = TeamLibraryPublishOutcome(failure: error, action: .publish)
        }
    }
}

enum TeamLibraryDestinationPage: Hashable {
    case query(teamID: String, queryID: String)
    case unsent
    case keys(teamID: String)
}

private struct TeamLibraryConnectionChoice: Identifiable {
    let team: TeamLibraryTeam
    let item: TeamLibraryConnectionItem
    let destination: TeamLibraryDestination

    var id: String { team.id + "\n" + item.id }
}

private struct TeamLibraryRemoval: Identifiable {
    let team: TeamLibraryTeam
    let ref: TeamLibraryItemRef
    let name: String
    let destination: TeamLibraryDestination

    var id: String { team.id + "\n" + ref.id }

    var title: String {
        String(format: String(localized: "Remove “%@” from %@?"), name, team.name)
    }
}

struct TeamLibraryStatusRow: View {
    let status: TeamLibraryStatus

    var body: some View {
        switch status {
        case .idle:
            LabeledContent(String(localized: "Status"), value: String(localized: "Waiting for the first download"))
        case .syncing:
            LabeledContent(String(localized: "Status")) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing…")
                }
            }
        case .synced(let date):
            LabeledContent(String(localized: "Last Synced")) {
                Text(date, style: .relative)
            }
        case .failed(let problem):
            Label {
                Text(problem.message)
                    .font(.subheadline)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct TeamLibraryConnectionRow: View {
    let item: TeamLibraryConnectionItem

    // The same reading of the settings a copy gets, so the row shows what adding it would keep.
    private var connection: DatabaseConnection {
        DatabaseConnection(importedSettings: item.settings)
    }

    var body: some View {
        let connection = connection
        HStack(spacing: 12) {
            ConnectionTile(type: connection.type, iconName: connection.iconName, color: connection.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.settings.name)
                Text(verbatim: MacOnlyConnection.isMacOnly(connection)
                    ? MacOnlyConnection.status
                    : TeamLibraryVisibleText.name(ConnectionDetailFormatter.detail(for: connection)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let change = TeamLibraryChangeText.text(item.change) {
                    Text(verbatim: change)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct TeamLibraryQueryRow: View {
    let query: TeamLibraryQueryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(verbatim: query.name)
            } icon: {
                Image(systemName: "doc.text")
            }
            if let detail = TeamLibraryChangeText.text(query.change) ?? query.folderName {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum TeamLibraryChangeText {
    // "Changed by Ana, 3 hours ago": who last changed it and when, as far as the server names either.
    static func text(_ change: TeamLibraryChange) -> String? {
        let when = change.date.map { $0.formatted(.relative(presentation: .named)) }
        switch (change.writer, when) {
        case let (writer?, when?):
            return String(format: String(localized: "Changed by %1$@, %2$@"), writer, when)
        case let (writer?, nil):
            return String(format: String(localized: "Changed by %@"), writer)
        case let (nil, when?):
            return String(format: String(localized: "Changed %@"), when)
        case (nil, nil):
            return nil
        }
    }
}

private struct TeamLibraryQueryPublish: Identifiable {
    let team: TeamLibraryTeam
    let destination: TeamLibraryDestination

    var id: String { team.id }
}
