import SwiftUI
import TableProFFI
import UIKit

// A team's saved query: what it runs and who changed it last. The SQL another member wrote is shown, never run here.
struct TeamQueryDetailView: View {
    let query: TeamLibraryQueryItem

    var body: some View {
        List {
            Section {
                if let folder = query.folderName {
                    LabeledContent(String(localized: "Folder"), value: folder)
                }
                if let keyword = query.keyword, !keyword.isEmpty {
                    LabeledContent(String(localized: "Keyword"), value: TeamLibraryVisibleText.name(keyword))
                }
                if let change = TeamLibraryChangeText.text(query.change) {
                    Text(verbatim: change)
                        .foregroundStyle(.secondary)
                }
            }
            Section("SQL") {
                Text(verbatim: TeamLibraryVisibleText.visible(query.query, keepingLineBreaks: true))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = query.query
                } label: {
                    Label(String(localized: "Copy SQL"), systemImage: "doc.on.doc")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(query.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Edits the teams have not taken yet, by team, with what holds each: Send Now tries them again, Discard drops them.
struct TeamUnsentEditsView: View {
    @Environment(AppState.self) private var appState
    @State private var pendingDiscard: TeamUnsentDiscard?
    @State private var failure: TeamActionFailure?
    @State private var isSending = false

    private var library: TeamLibraryModel {
        appState.teamLibrary
    }

    private var groups: [TeamUnsentGroup] {
        Dictionary(grouping: library.unsent, by: \.teamId)
            .map { TeamUnsentGroup(team: $0.key, edits: $0.value) }
            .sorted { teamName($0.team).localizedLowercase < teamName($1.team).localizedLowercase }
    }

    var body: some View {
        List {
            if library.unsent.isEmpty {
                Text("Every edit reached its team.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.edits, id: \.item) { edit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: edit.name.flatMap { $0.isEmpty ? nil : TeamLibraryVisibleText.name($0) } ?? edit.item.id)
                            Text(TeamLibraryModel.state(of: edit))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Button(String(localized: "Discard This Team's Edits…"), role: .destructive) {
                        pendingDiscard = TeamUnsentDiscard(team: group.team, name: teamName(group.team))
                    }
                } header: {
                    Text(verbatim: teamName(group.team))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Not Sent Yet"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isSending {
                    ProgressView()
                } else {
                    Button(String(localized: "Send Now")) {
                        Task { await sendNow() }
                    }
                    .disabled(library.unsent.isEmpty)
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button(String(localized: "Discard All…"), role: .destructive) {
                    pendingDiscard = TeamUnsentDiscard(team: nil, name: nil)
                }
                .disabled(library.unsent.isEmpty)
            }
        }
        .confirmationDialog(
            pendingDiscard?.title ?? "",
            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
            titleVisibility: .visible,
            presenting: pendingDiscard
        ) { discard in
            Button(String(localized: "Discard"), role: .destructive) {
                Task { await self.discard(discard) }
            }
        } message: { _ in
            Text("The team keeps its own version. Your edits on this device are deleted.")
        }
        .alert(
            failure?.title ?? "",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
    }

    private func teamName(_ id: String) -> String {
        library.team(id)?.name ?? String(localized: "A team you left")
    }

    private func sendNow() async {
        isSending = true
        defer { isSending = false }
        do throws(TeamLibraryProblem) {
            try await library.sendUnsent()
        } catch {
            failure = TeamActionFailure(title: String(localized: "Couldn't Send the Edits"), message: error.message)
        }
    }

    private func discard(_ discard: TeamUnsentDiscard) async {
        do throws(TeamLibraryProblem) {
            try await library.discardUnsent(team: discard.team)
        } catch {
            failure = TeamActionFailure(title: String(localized: "Couldn't Discard the Edits"), message: error.message)
        }
    }
}

private struct TeamUnsentGroup: Identifiable {
    let team: String
    let edits: [UnsentTeamEditInfo]

    var id: String { team }
}

private struct TeamUnsentDiscard: Identifiable {
    let team: String?
    let name: String?

    var id: String { team ?? "" }

    var title: String {
        guard let name else { return String(localized: "Discard every unsent Team Library edit?") }
        return String(format: String(localized: "Discard the unsent edits for %@?"), name)
    }
}

// One team conflict at a time while the engine holds any: the fields both sides changed, side by side, then Keep Mine
// or Keep Theirs. Decide Later only closes the sheet.
struct TeamConflictSheet: View {
    let model: TeamConflictsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let conflict = model.conflicts.first {
                    TeamConflictContent(
                        presentation: TeamConflictPresentation(
                            conflict: conflict,
                            teamName: model.teamName(of: conflict.record.scope),
                            writer: model.writer(of: conflict.record)
                        ),
                        remaining: model.conflicts.count,
                        isResolving: model.resolving != nil,
                        failure: model.failure(for: conflict.record),
                        keep: { choice in
                            Task { await model.resolve(conflict, keep: choice) }
                        }
                    )
                } else {
                    ContentUnavailableView(String(localized: "No Conflicts"), systemImage: "checkmark.circle")
                }
            }
            .navigationTitle(String(localized: "Team Library Conflict"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Decide Later")) { dismiss() }
                }
            }
        }
        .onChange(of: model.conflicts.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }
}

private struct TeamConflictContent: View {
    let presentation: TeamConflictPresentation
    let remaining: Int
    let isResolving: Bool
    let failure: String?
    let keep: (ConflictChoiceTag) -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: presentation.title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: presentation.message)
                        .foregroundStyle(.secondary)
                }
                if let writer = presentation.writer {
                    LabeledContent(String(localized: "Changed By"), value: writer)
                }
                if remaining > 1 {
                    Text(String(format: String(localized: "%lld conflicts left"), Int64(remaining)))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(presentation.rows) { row in
                Section(row.label) {
                    if presentation.shape != .youDeleted {
                        TeamConflictValueRow(title: String(localized: "Your Version"), value: row.mine ?? .notSet)
                    }
                    if presentation.shape != .teamDeleted {
                        TeamConflictValueRow(title: String(localized: "Team's Version"), value: row.theirs ?? .notSet)
                    }
                }
            }
            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    keep(.keepMine)
                } label: {
                    Text("Keep Mine")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityHint(Text(presentation.keepMineHint))
                Button {
                    keep(.keepTheirs)
                } label: {
                    Text("Keep Theirs")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(Text(presentation.keepTheirsHint))
            }
            .controlSize(.large)
            .disabled(isResolving)
            .padding()
            .background(.bar)
        }
    }
}

private struct TeamConflictValueRow: View {
    let title: String
    let value: TeamConflictPresentation.Value

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            switch value {
            case .text(let text):
                Text(verbatim: text)
                    .textSelection(.enabled)
            case .code(let code):
                Text(verbatim: code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            case .empty, .notSet:
                Text(TeamConflictPresentation.spoken(value))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title), \(TeamConflictPresentation.spoken(value))"))
    }
}
