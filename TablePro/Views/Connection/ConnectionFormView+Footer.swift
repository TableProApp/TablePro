//
//  ConnectionFormView+Footer.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import SwiftUI
import TableProPluginKit

// MARK: - Footer

extension ConnectionFormView {
    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Test connection
                Button(action: testConnection) {
                    HStack(spacing: 6) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else if testSucceeded {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(nsColor: .systemGreen))
                        } else {
                            Image(systemName: "bolt.horizontal")
                                .foregroundStyle(.secondary)
                        }
                        Text(testSucceeded ? String(localized: "Connected") : String(localized: "Test Connection"))
                    }
                }
                .disabled(isTesting || isInstallingPlugin || !isValid)

                Spacer()

                // Delete button (edit mode only)
                if !isNew {
                    Button("Delete", role: .destructive) {
                        Task {
                            let confirmed = await AlertHelper.confirmDestructive(
                                title: String(localized: "Delete Connection"),
                                message: String(localized: "Are you sure you want to delete this connection? This cannot be undone."),
                                confirmButton: String(localized: "Delete"),
                                window: NSApp.keyWindow
                            )
                            if confirmed {
                                deleteConnection()
                            }
                        }
                    }
                }

                // Cancel
                Button("Cancel") {
                    NSApplication.shared.closeWindows(withId: "connection-form")
                }

                // Save
                Button(isNew ? String(localized: "Create") : String(localized: "Save")) {
                    saveConnection()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(isInstallingPlugin || !isValid)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand {
            NSApplication.shared.closeWindows(withId: "connection-form")
        }
        .onChange(of: host) { _, _ in testSucceeded = false }
        .onChange(of: port) { _, _ in testSucceeded = false }
        .onChange(of: username) { _, _ in testSucceeded = false }
        .onChange(of: password) { _, _ in testSucceeded = false }
        .onChange(of: database) { _, _ in testSucceeded = false }
        .onChange(of: type) { _, _ in testSucceeded = false }
        .onChange(of: sshState.enabled) { _, _ in testSucceeded = false }
        .onChange(of: sshState.host) { _, _ in testSucceeded = false }
        .onChange(of: sshState.port) { _, _ in testSucceeded = false }
        .onChange(of: sshState.username) { _, _ in testSucceeded = false }
        .onChange(of: sshState.authMethod) { _, _ in testSucceeded = false }
        .onChange(of: sslMode) { _, _ in testSucceeded = false }
    }

    // MARK: - Import from URL Sheet

    var connectionURLImportSheet: some View {
        VStack(spacing: 16) {
            Text(String(localized: "Import from URL"))
                .font(.headline)

            Text(String(localized: "Paste a connection URL to auto-fill the form fields."))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField(
                String(localized: "Connection URL"),
                text: $connectionURL,
                prompt: Text("postgresql://user:password@host:5432/database")
            )
            .textFieldStyle(.roundedBorder)

            if let urlParseError {
                Text(urlParseError)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
            }

            HStack {
                Button(String(localized: "Cancel")) {
                    showURLImport = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "Import")) {
                    parseConnectionURL()
                    if urlParseError == nil && !connectionURL.isEmpty {
                        connectionURL = ""
                        urlParseError = nil
                        showURLImport = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(connectionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
