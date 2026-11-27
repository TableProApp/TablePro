import SwiftUI
import TableProModels

// What a publish or a removal ended with, worded for its alert.
struct TeamLibraryPublishOutcome: Identifiable {
    enum Action {
        case publish
        case remove
    }

    let title: String
    let message: String
    let offersConflicts: Bool

    var id: String { title + "\n" + message }

    init(_ result: TeamLibraryPublishResult, action: Action) {
        switch result {
        case .unchanged:
            title = String(localized: "Already Up to Date")
            message = String(localized: "The team already has this version.")
            offersConflicts = false
        case .published(let count):
            title = action == .remove ? String(localized: "Removed from Team") : String(localized: "Published")
            message = count == 1
                ? String(localized: "1 change went to the team.")
                : String(format: String(localized: "%lld changes went to the team."), Int64(count))
            offersConflicts = false
        case .conflicts(let count):
            title = String(localized: "Someone Else Changed These Too")
            message = count == 1
                ? String(localized: "1 item changed on the team since you last synced. Choose which version to keep.")
                : String(format: String(localized: "%lld items changed on the team since you last synced. Choose which version to keep."), Int64(count))
            offersConflicts = true
        case .queued(let problem):
            title = String(localized: "Waiting to Send")
            message = problem.message
            offersConflicts = false
        }
    }

    init(failure: TeamLibraryProblem, action: Action) {
        title = action == .remove ? String(localized: "Couldn't Remove from Team") : String(localized: "Couldn't Publish")
        message = failure.message
        offersConflicts = false
    }
}

// Connections the person asked to publish, and the team picked, taken before the confirmation waits.
struct TeamPublishRequest: Identifiable {
    let connections: [DatabaseConnection]
    let team: TeamLibraryTeam
    let destination: TeamLibraryDestination

    var id: String { team.id + "\n" + connections.map(\.id.uuidString).joined(separator: ",") }

    var title: String {
        guard connections.count == 1, let connection = connections.first else {
            return String(format: String(localized: "Publish %lld connections to %@?"), Int64(connections.count), team.name)
        }
        return String(format: String(localized: "Publish “%1$@” to %2$@?"), connection.name, team.name)
    }
}

// The "Publish to Team" items of a connection's menu: one item for one team, a submenu for several.
struct TeamPublishMenu: View {
    let connections: [DatabaseConnection]
    let library: TeamLibraryModel
    let request: (TeamPublishRequest) -> Void

    var body: some View {
        let teams = library.writableTeams
        if teams.count == 1, let team = teams.first {
            Button {
                request(TeamPublishRequest(connections: connections, team: team, destination: library.destination(team.id)))
            } label: {
                Label(String(localized: "Publish to Team…"), systemImage: "person.2.badge.plus")
            }
        } else if teams.count > 1 {
            Menu {
                ForEach(teams) { team in
                    Button(team.name) {
                        request(TeamPublishRequest(connections: connections, team: team, destination: library.destination(team.id)))
                    }
                }
            } label: {
                Label(String(localized: "Publish to Team"), systemImage: "person.2.badge.plus")
            }
        }
    }
}

// The confirmation, the publish and its outcome for a request the connection list made.
struct TeamPublishing: ViewModifier {
    @Binding var request: TeamPublishRequest?
    let library: TeamLibraryModel
    let openTeamLibrary: () -> Void

    @State private var outcome: TeamLibraryPublishOutcome?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                request?.title ?? "",
                isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                titleVisibility: .visible,
                presenting: request
            ) { request in
                Button(String(localized: "Publish")) {
                    Task { await publish(request) }
                }
            } message: { _ in
                Text("Everyone on the team will see the host, port, user, database and SSH settings. Publishing again updates the team's copy. Passwords are not included.")
            }
            .alert(
                outcome?.title ?? "",
                isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } }),
                presenting: outcome
            ) { outcome in
                if outcome.offersConflicts {
                    Button(String(localized: "Review")) { openTeamLibrary() }
                }
                Button(String(localized: "OK"), role: .cancel) {}
            } message: { outcome in
                Text(outcome.message)
            }
    }

    private func publish(_ request: TeamPublishRequest) async {
        do throws(TeamLibraryProblem) {
            outcome = TeamLibraryPublishOutcome(
                try await library.publishConnections(request.connections, to: request.destination),
                action: .publish
            )
        } catch {
            outcome = TeamLibraryPublishOutcome(failure: error, action: .publish)
        }
    }
}

extension View {
    func teamPublishing(
        _ request: Binding<TeamPublishRequest?>,
        library: TeamLibraryModel,
        openTeamLibrary: @escaping () -> Void
    ) -> some View {
        modifier(TeamPublishing(request: request, library: library, openTeamLibrary: openTeamLibrary))
    }
}
