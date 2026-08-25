//
//  LicenseDevicesSection.swift
//  TablePro
//

import SwiftUI

/// The Macs this license is activated on, and the way to give a seat back.
///
/// A `List` rather than a `Table`: every `Table` in the app is the sole content of its own pane,
/// and the proven shape for a list inside a grouped `Form` is `MCPTokenListView`, bounded by an
/// explicit height because a list will not size itself to its content here.
struct LicenseDevicesSection: View {
    private let licenseManager = LicenseManager.shared

    @State private var releaseCandidate: LicenseActivationInfo?

    var body: some View {
        Section {
            switch licenseManager.deviceListState {
            case .idle, .loading:
                loadingRow
            case .failed(let message):
                failureRow(message)
            case .loaded:
                deviceList
            }
        } header: {
            HStack {
                Text("Devices")
                Spacer()
                if licenseManager.isRefreshingDevices {
                    ProgressView().controlSize(.small)
                }

                if licenseManager.deviceListState == .loaded {
                    Text(
                        LicensePresentation.deviceCount(
                            used: licenseManager.devices.count,
                            limit: licenseManager.maxDevices
                        )
                    )
                    .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if licenseManager.license?.isTeamLicense == true {
                Text("Seats on a team license are managed on tablepro.app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await licenseManager.loadDevices() }
        .alert(
            releaseCandidate.map(releaseTitle(for:)) ?? "",
            isPresented: releaseAlertBinding,
            presenting: releaseCandidate
        ) { device in
            Button(String(localized: "Cancel"), role: .cancel) {
                releaseCandidate = nil
            }
            Button(String(localized: "Release"), role: .destructive) {
                releaseCandidate = nil
                Task { await licenseManager.releaseDevice(device) }
            }
        } message: { device in
            Text(releaseMessage(for: device))
        }
    }

    private var releaseAlertBinding: Binding<Bool> {
        Binding(
            get: { releaseCandidate != nil },
            set: { presented in
                if !presented { releaseCandidate = nil }
            }
        )
    }

    // MARK: - Rows

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading devices…")
                .foregroundStyle(.secondary)
        }
    }

    private func failureRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            Button(String(localized: "Try Again")) {
                Task { await licenseManager.loadDevices(force: true) }
            }
        }
    }

    @ViewBuilder
    private var deviceList: some View {
        if licenseManager.devices.isEmpty {
            Text("No devices are activated on this license.")
                .foregroundStyle(.secondary)
        } else {
            List(licenseManager.devices) { device in
                deviceRow(device)
            }
            .listStyle(.inset)
            .frame(minHeight: 96, maxHeight: 190)
        }

        if let message = licenseManager.releaseErrorMessage ?? licenseManager.refreshErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deviceRow(_ device: LicenseActivationInfo) -> some View {
        let isThisMac = device.machineId == licenseManager.currentMachineId

        return HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.machineName)
                    .fontWeight(isThisMac ? .semibold : .regular)
                    .lineLimit(1)

                Text(secondaryLine(for: device, isThisMac: isThisMac))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if licenseManager.releasingMachineIds.contains(device.machineId) {
                ProgressView().controlSize(.small)
            } else if !isThisMac, licenseManager.canReleaseOtherDevices {
                Button(String(localized: "Release…")) {
                    releaseCandidate = device
                }
                .accessibilityLabel(
                    Text(String(format: String(localized: "Release the seat on %@"), device.machineName))
                )
                .accessibilityIdentifier("license-release-\(device.machineId)")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    /// Which Mac you are on, when it last checked in, and what it is running. Last use is the fact
    /// somebody actually decides on when choosing a seat to release, so it earns its place over the
    /// app version, which is carried only for this Mac where the OS line is already short.
    private func secondaryLine(for device: LicenseActivationInfo, isThisMac: Bool) -> String {
        var parts: [String] = []

        if isThisMac {
            parts.append(String(localized: "This Mac"))
        } else if let lastUsed = Self.lastUsedDescription(device) {
            parts.append(lastUsed)
        }

        parts.append(device.osVersion)
        return parts.joined(separator: " · ")
    }

    private static let lastValidatedFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func lastUsedDescription(_ device: LicenseActivationInfo) -> String? {
        guard let raw = device.lastValidatedAt,
              let date = lastValidatedFormatter.date(from: raw) else { return nil }

        return String(
            format: String(localized: "Last used %@"),
            date.formatted(.relative(presentation: .named))
        )
    }

    /// Only another Mac reaches this, so the copy speaks about that Mac. Giving up this Mac's own
    /// seat goes through the pane's single Deactivate control instead, which is the split Apple's
    /// own Apple Account pane makes: the device list removes other devices, never the one in front
    /// of you.
    private func releaseTitle(for device: LicenseActivationInfo) -> String {
        String(format: String(localized: "Release the seat on “%@”?"), device.machineName)
    }

    private func releaseMessage(for device: LicenseActivationInfo) -> String {
        String(localized: "That Mac keeps working until its next check, within 7 days, and then Pro features pause there.")
    }
}
