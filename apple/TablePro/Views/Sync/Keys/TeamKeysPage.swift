//
//  TeamKeysPage.swift
//  TablePro
//

import SwiftUI
import TableProFFI

// Settings > Account > Teams > a team: its end-to-end keys (core ADR 0056, Teams).
internal struct TeamKeysPage: View {
    @StateObject private var model: TeamKeysModel
    private let manage: URL?
    private let openPortal: (URL) -> Void

    init(team: TeamKeysTeam, manage: URL?, openPortal: @escaping (URL) -> Void) {
        self.init(model: TeamKeysModel(team: team), manage: manage, openPortal: openPortal)
    }

    init(model: @autoclosure @escaping () -> TeamKeysModel, manage: URL?, openPortal: @escaping (URL) -> Void) {
        _model = StateObject(wrappedValue: model())
        self.manage = manage
        self.openPortal = openPortal
    }

    var body: some View {
        Form {
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
                Button(String(localized: "Show My Words…")) { model.sheet = .ownWords }
                if let manage {
                    Button(String(localized: "Manage on the Web…")) { openPortal(manage) }
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-page-team-keys")
        .task { await model.load() }
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
            Button(String(localized: "OK")) {}
        } message: { failure in
            Text(failure.message)
        }
        .confirmationDialog(
            String(localized: "Rotate the team key?"),
            isPresented: $model.asksRotation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Rotate")) { Task { await model.rotate() } }
            Button(String(localized: "Cancel"), role: .cancel) {}
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
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text("Confirming it again rotates the team key. Every confirmed member, that device included, gets the new key.")
        }
    }
}

private struct TeamKeyStatusSection: View {
    @ObservedObject var model: TeamKeysModel

    var body: some View {
        Section(String(localized: "Team Key")) {
            if let status = model.status {
                row(status)
            } else if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Loading team keys")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if let failure = model.loadFailure {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    NoticeLabel(failure)
                    Spacer(minLength: 12)
                    if model.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text("Loading"))
                    } else {
                        Button(String(localized: "Try Again")) { Task { await model.load() } }
                            .fixedSize()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ status: TeamKeyStatus) -> some View {
        switch status {
        case .ended:
            NoticeLabel(
                String(localized: "This team's keys ended on this Mac. An owner needs to create a new team and share its connections again."),
                severity: .error
            )
        case .stoppedCatchUp(let version):
            NoticeLabel(stoppedText(version))
        case .restoreWait:
            NoticeLabel(
                String(localized: "The server lost a team key in a restore. This Mac waits until the device that made it sends it again, then carries on by itself."),
                severity: .info
            )
        case .restartHeld:
            actionRow(
                NoticeLabel(String(localized: "The team key was started over. Compare the words of the owner who did it before this Mac uses it.")),
                title: String(localized: "Compare Words…")
            ) { model.sheet = .heldRestart }
        case .noKeys(let canCreate):
            if canCreate {
                actionRow(
                    Text("This team has no keys yet. Create them to share passwords with the team end-to-end.")
                        .fixedSize(horizontal: false, vertical: true),
                    title: String(localized: "Create Team Keys")
                ) { Task { await model.createKeys() } }
            } else {
                Text("The team's owner hasn't set up its keys yet.")
                    .foregroundStyle(.secondary)
            }
        case .noHolderLeft(let canRestart):
            if canRestart {
                actionRow(
                    NoticeLabel(String(localized: "No one on this team holds the current team key. Start it over to share passwords with the team again.")),
                    title: String(localized: "Start Over…")
                ) { model.sheet = .restart }
            } else {
                NoticeLabel(String(localized: "No one on this team holds the current team key. An owner needs to start it over."))
            }
        case .awaitingConfirmation:
            actionRow(
                Text("Waiting for an owner or admin to confirm you. Show them your words so they can compare.")
                    .fixedSize(horizontal: false, vertical: true),
                title: String(localized: "Show My Words…")
            ) { model.sheet = .ownWords }
        case .rotationDue:
            actionRow(
                NoticeLabel(String(localized: "A team key rotation is due. New passwords for this team wait until the key is rotated.")),
                title: String(localized: "Rotate Team Key…")
            ) { model.asksRotation = true }
        case .holder(let version):
            LabeledContent(String(localized: "Team key")) {
                Text(String(format: String(localized: "Version %lld"), Int64(version)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("This Mac holds the team key and can share passwords with the team.")
                .foregroundStyle(.secondary)
        }
    }

    private func stoppedText(_ version: UInt32?) -> String {
        guard let version else {
            return String(localized: "This Mac stopped using the team key: it couldn't verify a newer version. An owner or admin needs to confirm this Mac again.")
        }
        return String(
            format: String(localized: """
                This Mac stopped using the team key: it couldn't verify a newer version. An owner or admin who held version \
                %lld needs to confirm this Mac again. TablePro has let them know.
                """),
            Int64(version)
        )
    }

    private func actionRow(_ label: some View, title: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            label
            Spacer(minLength: 12)
            Button(title, action: action)
                .fixedSize()
                .disabled(model.work != nil)
        }
    }
}

private struct TeamKeyNoticesSection: View {
    @ObservedObject var model: TeamKeysModel

    var body: some View {
        Section(String(localized: "Alerts")) {
            ForEach(model.notices) { notice in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    NoticeLabel(notice.text, severity: notice.severity)
                    Spacer(minLength: 12)
                    if let action = notice.action {
                        Button(String(localized: "Compare…")) { model.noticeAction(action) }
                            .fixedSize()
                    }
                    Button(String(localized: "Dismiss")) { Task { await model.dismiss(notice) } }
                        .fixedSize()
                        .disabled(model.work != nil)
                }
            }
        }
    }
}

private struct TeamMembersSection: View {
    @ObservedObject var model: TeamKeysModel
    let snapshot: TeamKeysSnapshot

    var body: some View {
        Section(String(localized: "Members")) {
            if snapshot.members.isEmpty {
                Text("No members yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshot.members) { member in
                SettingsRecordRow(
                    title: TeamKeysPresentation.memberTitle(member),
                    subtitle: TeamKeysPresentation.statusText(of: member),
                    value: TeamKeysPresentation.roleName(member.role)
                ) {
                    trailing(member)
                }
            }
        }
    }

    @ViewBuilder
    private func trailing(_ member: TeamMemberKeys) -> some View {
        if model.work == .confirming(member.account) || model.work == .accepting(member.account) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Working"))
        } else {
            switch model.action(for: member) {
            case .confirm:
                Button(String(localized: "Confirm…")) { model.sheet = .confirm(member) }
                    .fixedSize()
                    .disabled(model.work != nil)
                    .accessibilityLabel(Text(String(format: String(localized: "Confirm %@"), member.displayName)))
            case .compareKeyChange:
                Button(String(localized: "Compare…")) { model.sheet = .keyChange(member) }
                    .fixedSize()
                    .disabled(model.work != nil)
                    .accessibilityLabel(Text(String(format: String(localized: "Compare %@'s words"), member.displayName)))
            case nil:
                EmptyView()
            }
        }
    }
}

private struct TeamStoppedDevicesSection: View {
    @ObservedObject var model: TeamKeysModel
    let snapshot: TeamKeysSnapshot

    var body: some View {
        Section {
            ForEach(snapshot.stoppedDevices) { device in
                SettingsRecordRow(title: title(device), subtitle: subtitle(device)) {
                    if device.canReconfirm {
                        Button(String(localized: "Confirm Again…")) { model.pendingReconfirm = device }
                            .fixedSize()
                            .disabled(model.work != nil)
                    }
                }
            }
        } header: {
            Text("Stopped Devices")
        } footer: {
            Text("""
                These devices couldn't verify a newer team key and stopped using it. An owner or admin who held the version a \
                device stopped at confirms it again by rotating the key.
                """)
        }
    }

    private func title(_ device: TeamStoppedDevice) -> String {
        let owner = device.ownerName ?? snapshot.member(device.account)?.displayName
        switch (owner, device.deviceName) {
        case let (owner?, deviceName?):
            return String(format: String(localized: "%1$@'s %2$@"), owner, deviceName)
        case let (owner?, nil):
            return String(format: String(localized: "%@'s device"), owner)
        case (nil, _):
            return String(localized: "A member's device")
        }
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
                SettingsRecordRow(
                    title: credential.connectionName ?? String(localized: "A team connection"),
                    subtitle: TeamKeysPresentation.secretName(credential.fieldKey) {
                        TeamKeysPresentation.driverFieldLabel($0, driver: credential.driver)
                    }
                )
            }
        } header: {
            Text("Credentials to Rotate")
        } footer: {
            Text("Someone who left this team could read these before they left. Change them on the database servers, then save the new ones in TablePro.")
        }
    }
}
