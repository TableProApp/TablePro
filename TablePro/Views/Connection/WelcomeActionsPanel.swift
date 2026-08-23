//
//  WelcomeActionsPanel.swift
//  TablePro
//

import SwiftUI

struct WelcomeActionsPanel: View {
    let onActivateLicense: () -> Void
    let onCreateConnection: () -> Void
    let onImportFromURL: () -> Void
    let onImportFromApp: () -> Void
    let onOpenProjectFolder: () -> Void
    let onImportConnectionsFile: () -> Void

    private let updaterBridge = UpdaterBridge.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)

                VStack(spacing: 6) {
                    Text(verbatim: "TablePro")
                        .font(.title2.weight(.semibold))

                    versionLine

                    licenseLine
                }
            }

            Spacer()
                .frame(height: 28)

            VStack(spacing: 8) {
                Button(action: onCreateConnection) {
                    Label(String(localized: "Create Connection…"), systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Menu {
                    Button(String(localized: "Import from URL…"), action: onImportFromURL)
                    Button(String(localized: "Import from Other App…"), action: onImportFromApp)
                    Button(String(localized: "Open Project Folder…"), action: onOpenProjectFolder)
                    Divider()
                    Button(String(localized: "Import Connections…"), action: onImportConnectionsFile)
                } label: {
                    Label(String(localized: "Add from Existing"), systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)

            Spacer()

            SyncStatusIndicator(onActivateLicense: onActivateLicense)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var versionLine: some View {
        HStack(spacing: 6) {
            Text(String(format: String(localized: "Version %@"), Bundle.main.appVersion))
                .foregroundStyle(.secondary)
            Text(verbatim: "·")
                .foregroundStyle(.tertiary)
            Button {
                updaterBridge.checkForUpdates()
            } label: {
                Text(String(localized: "Check for Updates…"))
            }
            .buttonStyle(.link)
            .disabled(!updaterBridge.canCheckForUpdates)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var licenseLine: some View {
        if LicenseManager.shared.status.isValid {
            Label(String(localized: "Pro"), systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
        } else {
            Button(action: onActivateLicense) {
                Text(String(localized: "Activate License"))
                    .font(.subheadline)
            }
            .buttonStyle(.link)
        }
    }
}
