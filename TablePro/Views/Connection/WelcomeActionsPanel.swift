//
//  WelcomeActionsPanel.swift
//  TablePro
//

import SwiftUI

struct WelcomeActionsPanel: View {
    let onActivateLicense: () -> Void
    let onCreateConnection: () -> Void
    let onImportFromApp: () -> Void
    let onTrySample: () -> Void

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
                    Label(String(localized: "Create Connection..."), systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onImportFromApp) {
                    Label(String(localized: "Import from Other App..."), systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: onTrySample) {
                    Label(String(localized: "Try Sample Database"), systemImage: "cylinder.split.1x2")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)

            Spacer()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    SyncStatusIndicator(onActivateLicense: onActivateLicense)
                    KeyboardHint(keys: "⌘N", label: String(localized: "New"))
                    KeyboardHint(keys: "⌘,", label: String(localized: "Settings"))
                }
                HStack(spacing: 8) {
                    SyncStatusIndicator(onActivateLicense: onActivateLicense)
                    KeyboardHint(keys: "⌘N", label: String(localized: "New"))
                    KeyboardHint(keys: "⌘,", label: nil)
                }
            }
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
                Text(String(localized: "Check for Updates..."))
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
                .foregroundStyle(Color(nsColor: .systemGreen))
        } else {
            Button(action: onActivateLicense) {
                Text(String(localized: "Activate License"))
                    .font(.subheadline)
            }
            .buttonStyle(.link)
        }
    }
}

struct KeyboardHint: View {
    let keys: String
    let label: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.tertiary.opacity(0.4))
                )
            if let label {
                Text(label)
            }
        }
    }
}
