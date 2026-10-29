//
//  DeviceLimitSheet.swift
//  TablePro
//

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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "laptopcomputer.and.iphone")
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
            }

            VStack(spacing: 0) {
                ForEach(model.rows) { row in
                    if row.id != model.rows.first?.id {
                        Divider()
                    }
                    DeviceLimitRow(
                        row: row,
                        isRemoving: model.removing == row.id,
                        isDisabled: model.removing != nil
                    ) {
                        pendingRemoval = row
                    }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))

            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("device-limit-error")
            }

            HStack {
                Button(String(localized: "Manage Devices…")) {
                    openURL(model.services.configuration.portalDevices)
                }

                Spacer()

                Button(String(localized: "Not Now")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("device-limit-not-now")
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: model.isResolved) { isResolved in
            if isResolved { dismiss() }
        }
        .confirmationDialog(
            pendingRemoval.map { String(format: String(localized: "Remove “%@”?"), $0.name) } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { row in
            Button(String(localized: "Remove"), role: .destructive) {
                Task { await model.remove(row) }
            }
        } message: { _ in
            Text("TablePro on that device signs out the next time it checks your account, and this Mac takes its place.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("device-limit-sheet")
    }
}

private struct DeviceLimitRow: View {
    let row: DeviceLimitModel.Row
    let isRemoving: Bool
    let isDisabled: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(AccountDeviceText.detail(system: row.system, lastSeenAt: row.lastSeenAt))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if let offlineUntil = row.offlineUntil {
                Text(AccountDeviceText.offlineFile(until: offlineUntil))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            } else if isRemoving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Removing"))
            } else {
                Button(String(localized: "Remove"), action: onRemove)
                    .disabled(isDisabled)
                    .accessibilityLabel(Text(String(format: String(localized: "Remove %@"), row.name)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
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

    static func offlineFile(until date: Date) -> String {
        String(format: String(localized: "Offline file until %@"), date.formatted(date: .abbreviated, time: .omitted))
    }
}
