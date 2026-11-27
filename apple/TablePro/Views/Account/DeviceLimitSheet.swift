import SwiftUI

internal struct DeviceLimitSheet: View {
    @StateObject private var model: DeviceLimitModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var pendingRemoval: DeviceLimitModel.Row?

    init(model: @autoclosure @escaping () -> DeviceLimitModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Form {
                Section {
                    ForEach(model.rows) { row in
                        DeviceLimitRow(
                            row: row,
                            isRemoving: model.removing == row.id,
                            isDisabled: model.removing != nil
                        ) {
                            pendingRemoval = row
                        }
                    }

                    if let failure = model.failure {
                        NoticeLabel(failure)
                            .font(.subheadline)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("device-limit-error")
                    }
                }
            }
            .formStyle(.grouped)
            // A grouped Form answers any proposal with the whole height, so it alone is capped.
            .frame(height: 260)

            Divider()

            DialogFooter {
                Button(String(localized: "Manage Devices…")) {
                    openURL(model.services.portal.portalDevices)
                }
            } actions: {
                Button(String(localized: "Not Now")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("device-limit-not-now")
            }
            .padding(16)
        }
        .frame(width: 480)
        .onChange(of: model.isResolved) { isResolved in
            if isResolved { dismiss() }
        }
        .alert(
            pendingRemoval.map { String(format: String(localized: "Remove “%@”?"), $0.name) } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { row in
            Button(String(localized: "Remove"), role: .destructive) {
                Task { await model.remove(row) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text("TablePro on that device signs out the next time it checks your account, and this Mac takes its place.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("device-limit-sheet")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Your plan is in use on 3 other devices")
                    .font(.headline)

                Text("Remove one to use your plan on this Mac. Until then, TablePro works on the Free plan here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

private struct DeviceLimitRow: View {
    let row: DeviceLimitModel.Row
    let isRemoving: Bool
    let isDisabled: Bool
    let onRemove: () -> Void

    var body: some View {
        SettingsRecordRow(
            title: row.name,
            subtitle: AccountDeviceText.detail(system: row.system, lastSeenAt: row.lastSeenAt)
        ) {
            if let offlineUntil = row.offlineUntil {
                Text(AccountDeviceText.offlineFile(until: offlineUntil))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            } else if isRemoving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Removing"))
            } else {
                Button(String(localized: "Remove…"), action: onRemove)
                    .disabled(isDisabled)
                    .fixedSize()
                    .accessibilityLabel(Text(String(format: String(localized: "Remove %@"), row.name)))
            }
        }
        .contextMenu {
            if row.offlineUntil == nil {
                Button(String(localized: "Remove…"), action: onRemove)
                    .disabled(isDisabled)
            }
        }
    }
}

internal enum AccountDeviceText {
    static func detail(system: String, lastSeenAt: Date) -> String {
        let lastSeen = String(
            format: String(localized: "Last seen %@"),
            lastSeenAt.formatted(.relative(presentation: .named))
        )
        guard !system.isEmpty else { return lastSeen }
        return String(format: String(localized: "%@ · %@"), system, lastSeen)
    }

    // This Mac is the one showing the list, so it is seen now whatever the server last recorded.
    static func detail(system: String, lastSeenAt: Date, isThisDevice: Bool) -> String {
        guard isThisDevice else { return detail(system: system, lastSeenAt: lastSeenAt) }
        return String(format: String(localized: "%@ · %@"), String(localized: "This Mac"), detail(system: system, lastSeenAt: Date()))
    }

    static func offlineFile(until date: Date) -> String {
        String(format: String(localized: "Offline file until %@"), date.formatted(date: .abbreviated, time: .omitted))
    }
}
