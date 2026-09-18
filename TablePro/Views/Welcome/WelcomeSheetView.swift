//
//  WelcomeSheetView.swift
//  TablePro
//

import SwiftUI

internal struct WelcomeSheetView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)

                Text("Welcome to TablePro")
                    .font(.title.weight(.bold))
            }

            VStack(alignment: .leading, spacing: 16) {
                WelcomeSheetFeatureRow(
                    systemImage: "cylinder.split.1x2",
                    title: "Many Databases, One App",
                    message: "MySQL, PostgreSQL, SQLite, ClickHouse, and Redis are built in. Others install when you choose them."
                )
                WelcomeSheetFeatureRow(
                    systemImage: "tablecells",
                    title: "Edit Data in Place",
                    message: "Change cells in the grid and review the SQL before you save."
                )
                WelcomeSheetFeatureRow(
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    title: "Write and Run SQL",
                    message: "Autocomplete from your schema, editor tabs, and a searchable query history."
                )
                WelcomeSheetFeatureRow(
                    systemImage: "lock.shield",
                    title: "Connect Securely",
                    message: "Passwords stay in your Keychain. Tunnel through SSH or connect over SSL/TLS."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onContinue) {
                Text("Continue")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("welcome-sheet-continue")
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 32)
        .frame(width: 540)
        .onExitCommand(perform: onContinue)
    }
}

private struct WelcomeSheetFeatureRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Welcome Sheet") {
    WelcomeSheetView(onContinue: {})
}
