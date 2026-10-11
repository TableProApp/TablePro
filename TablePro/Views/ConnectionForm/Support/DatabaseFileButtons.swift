//
//  DatabaseFileButtons.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Browse… and New… beside a database file path, for every field that names the file a driver opens.
///
/// Two buttons rather than one pull-down: with only two choices the HIG prefers plain buttons, and a
/// menu would hide the one people could not find. New… appears only for a driver that creates a
/// missing file, since naming one for a driver that refuses it would only fail at connect.
struct DatabaseFileButtons: View {
    let type: DatabaseType
    @Binding var path: String

    private var newFileExtensions: [String] {
        PluginManager.shared.newDatabaseFileExtensions(for: type)
    }

    var body: some View {
        Button(String(localized: "Browse…")) {
            Task { await browse() }
        }
        .controlSize(.small)
        .help(String(localized: "Choose an existing database file"))
        .accessibilityIdentifier("connection-form-file-browse")

        if !newFileExtensions.isEmpty {
            Button(String(localized: "New…")) {
                Task { await nameNew() }
            }
            .controlSize(.small)
            .help(String(localized: "Name a new database file, created when you connect"))
            .accessibilityIdentifier("connection-form-file-new")
        }
    }

    private func browse() async {
        let chosen = await DatabaseFilePanel.chooseExisting(for: type, currentPath: path, in: NSApp.keyWindow)
        if let chosen { path = chosen }
    }

    private func nameNew() async {
        let chosen = await DatabaseFilePanel.nameNew(
            extensions: newFileExtensions,
            currentPath: path,
            in: NSApp.keyWindow
        )
        if let chosen { path = chosen }
    }
}
