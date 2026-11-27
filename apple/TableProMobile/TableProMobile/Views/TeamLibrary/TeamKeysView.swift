import SwiftUI
import TableProFFI

// A team's end-to-end keys (core ADR 0056, Teams): the team key's state, its members' keys, the devices stopped on it
// and what a removed party could read. Owners and admins confirm members, rotate and start the key over.
struct TeamKeysView: View {
    @State private var model: TeamKeysModel

    init(model: @autoclosure @escaping () -> TeamKeysModel) {
        _model = State(wrappedValue: model())
    }

    var body: some View {
        @Bindable var model = model
        List {
            TeamKeyStatusSection(model: model)

            if !model.notices.isEmpty {
                TeamKeyNoticesSection(model: model)
            }

            if let snapshot = model.snapshot {
                TeamMembersSection(model: model, snapshot: snapshot)

                if model.team.managesKeys, !snapshot.stoppedDevices.isEmpty {
                    TeamStoppedDevicesSection(model: model, snapshot: snapshot)
                }
            }

            if !model.credentials.isEmpty {
                TeamCredentialsSection(credentials: model.credentials)
            }

            Section {
                Button(String(localized: "Show My Words")) { model.sheet = .ownWords }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(model.team.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .confirm(let member):
                TeamMemberConfirmSheet(model: model, member: member)
            case .keyChange(let member):
                TeamKeyChangeSheet(model: model, member: member)
            case .heldRestart:
                TeamRestartHeldSheet(model: model)
            case .restart:
                TeamRestartSheet(model: model)
            case .ownWords:
                TeamOwnWordsSheet(model: model)
            }
        }
        .alert(
            model.failure?.title ?? "",
            isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
            presenting: model.failure
        ) { _ in
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        .confirmationDialog(
            String(localized: "Rotate the team key?"),
            isPresented: $model.asksRotation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Rotate")) { Task { await model.rotate() } }
        } message: {
            Text("Every confirmed member gets the new key. New passwords for this team can be saved again once it is done.")
        }
        .confirmationDialog(
            String(localized: "Confirm this device again?"),
            isPresented: Binding(
                get: { model.pendingReconfirm != nil },
                set: { if !$0 { model.pendingReconfirm = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingReconfirm
        ) { _ in
            Button(String(localized: "Rotate Team Key")) { Task { await model.rotate() } }
        } message: { _ in
            Text("Confirming it again rotates the team key. Every confirmed member, that device included, gets the new key.")
        }
    }
}

private struct TeamKeyStatusSection: View {
    let model: TeamKeysModel

    var body: some View {
        Section(String(localized: "Team Key")) {
            if let status = model.status {
                row(status)
            } else if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading team keys")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if let failure = model.loadFailure {
                TeamKeyNoticeLabel(text: failure, severity: .warning)
                Button(String(localized: "Try Again")) { Task { await model.load() } }
                    .disabled(model.isLoading)
            }
        }
    }

    @ViewBuilder
    private func row(_ status: TeamKeyStatus) -> some View {
        switch status {
        case .ended:
            TeamKeyNoticeLabel(
                text: String(localized: "This team's keys ended on this device. An owner needs to create a new team and share its connections again."),
                severity: .error
            )
        case .stoppedCatchUp(let version):
            TeamKeyNoticeLabel(text: stoppedText(version), severity: .warning)
        case .restoreWait:
            TeamKeyNoticeLabel(
                text: String(localized: "The server lost a team key in a restore. This device waits until the device that made it sends it again, then carries on by itself."),
                severity: .info
            )
        case .restartHeld:
            TeamKeyNoticeLabel(
                text: String(localized: "The team key was started over. Compare the words of the owner who did it before this device uses it."),
                severity: .warning
            )
            actionButton(String(localized: "Compare Words")) { model.sheet = .heldRestart }
        case .noKeys(let canCreate):
            if canCreate {
                Text("This team has no keys yet. Create them to share passwords with the team end-to-end.")
                actionButton(String(localized: "Create Team Keys")) { Task { await model.createKeys() } }
            } else {
                Text("The team's owner hasn't set up its keys yet.")
                    .foregroundStyle(.secondary)
            }
        case .noHolderLeft(let canRestart):
            if canRestart {
                TeamKeyNoticeLabel(
                    text: String(localized: "No one on this team holds the current team key. Start it over to share passwords with the team again."),
                    severity: .warning
                )
                actionButton(String(localized: "Start Over")) { model.sheet = .restart }
            } else {
                TeamKeyNoticeLabel(
                    text: String(localized: "No one on this team holds the current team key. An owner needs to start it over."),
                    severity: .warning
                )
            }
        case .awaitingConfirmation:
            Text("Waiting for an owner or admin to confirm you. Show them your words so they can compare.")
            actionButton(String(localized: "Show My Words")) { model.sheet = .ownWords }
        case .rotationDue:
            TeamKeyNoticeLabel(
                text: String(localized: "A team key rotation is due. New passwords for this team wait until the key is rotated."),
                severity: .warning
            )
            actionButton(String(localized: "Rotate Team Key")) { model.asksRotation = true }
        case .holder(let version):
            LabeledContent(String(localized: "Team Key")) {
                Text(String(format: String(localized: "Version %lld"), Int64(version)))
                    .monospacedDigit()
            }
            Text("This device holds the team key and can share passwords with the team.")
                .foregroundStyle(.secondary)
        }
    }

    private func stoppedText(_ version: UInt32?) -> String {
        guard let version else {
            return String(localized: "This device stopped using the team key: it couldn't verify a newer version. An owner or admin needs to confirm this device again.")
        }
        return String(
            format: String(localized: "This device stopped using the team key: it couldn't verify a newer version. An owner or admin who held version %lld needs to confirm this device again. TablePro has let them know."),
            Int64(version)
        )
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .disabled(model.work != nil)
    }
}

private struct TeamKeyNoticesSection: View {
    let model: TeamKeysModel

    var body: some View {
        Section(String(localized: "Alerts")) {
            ForEach(model.notices) { notice in
                VStack(alignment: .leading, spacing: 8) {
                    TeamKeyNoticeLabel(text: notice.text, severity: notice.severity)
                    HStack {
                        if let action = notice.action {
                            Button(String(localized: "Compare")) { model.noticeAction(action) }
                        }
                        Spacer()
                        Button(String(localized: "Dismiss")) { Task { await model.dismiss(notice) } }
                            .disabled(model.work != nil)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

private struct TeamMembersSection: View {
    let model: TeamKeysModel
    let snapshot: TeamKeysSnapshot

    var body: some View {
        Section(String(localized: "Members")) {
            if snapshot.members.isEmpty {
                Text("No members yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshot.members) { member in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: TeamKeysPresentation.memberTitle(member))
                        Text(TeamKeysPresentation.statusText(of: member))
                            .font(.subheadline)
                            .foregroundStyle(member.status == .alert ? Color.orange : Color.secondary)
                    }
                    Spacer(minLength: 8)
                    trailing(member)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    @ViewBuilder
    private func trailing(_ member: TeamMemberKeys) -> some View {
        if model.work == .confirming(member.account) || model.work == .accepting(member.account) {
            ProgressView()
                .accessibilityLabel(Text("Working"))
        } else {
            switch model.action(for: member) {
            case .confirm:
                Button(String(localized: "Confirm")) { model.sheet = .confirm(member) }
                    .buttonStyle(.bordered)
                    .disabled(model.work != nil)
                    .accessibilityLabel(Text(String(format: String(localized: "Confirm %@"), member.displayName)))
            case .compareKeyChange:
                Button(String(localized: "Compare")) { model.sheet = .keyChange(member) }
                    .buttonStyle(.bordered)
                    .disabled(model.work != nil)
                    .accessibilityLabel(Text(String(format: String(localized: "Compare %@'s words"), member.displayName)))
            case nil:
                Text(TeamKeysPresentation.roleName(member.role))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TeamStoppedDevicesSection: View {
    let model: TeamKeysModel
    let snapshot: TeamKeysSnapshot

    var body: some View {
        Section {
            ForEach(snapshot.stoppedDevices) { device in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title(device))
                    Text(subtitle(device))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if device.canReconfirm {
                        Button(String(localized: "Confirm Again")) { model.pendingReconfirm = device }
                            .buttonStyle(.borderless)
                            .disabled(model.work != nil)
                    }
                }
            }
        } header: {
            Text("Stopped Devices")
        } footer: {
            Text("These devices couldn't verify a newer team key and stopped using it. An owner or admin who held the version a device stopped at confirms it again by rotating the key.")
        }
    }

    private func title(_ device: TeamStoppedDevice) -> String {
        guard let owner = device.ownerName ?? snapshot.member(device.account)?.displayName else {
            return String(localized: "A member's device")
        }
        return String(format: String(localized: "%@'s device"), owner)
    }

    private func subtitle(_ device: TeamStoppedDevice) -> String {
        if device.canReconfirm {
            return String(format: String(localized: "Stopped at version %lld"), Int64(device.version))
        }
        return String(
            format: String(localized: "Stopped at version %lld. Only an owner or admin who held it can confirm it again."),
            Int64(device.version)
        )
    }
}

private struct TeamCredentialsSection: View {
    let credentials: [TeamCredentialToRotate]

    var body: some View {
        Section {
            ForEach(credentials) { credential in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: credential.connectionName ?? String(localized: "A team connection"))
                    Text(TeamKeysPresentation.secretName(credential.fieldKey))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Credentials to Rotate")
        } footer: {
            Text("Someone who left this team could read these before they left. Change them on the database servers, then save the new ones in TablePro.")
        }
    }
}

struct TeamKeyNoticeLabel: View {
    let text: String
    let severity: TeamKeyNoticeSeverity

    var body: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
    }

    private var symbol: String {
        switch severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private var tint: Color {
        switch severity {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
