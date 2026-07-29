//
//  CommandLineToolSection.swift
//  TablePro
//

import AppKit
import SwiftUI

struct CommandLineToolSection: View {
    private let installer: CommandLineToolInstalling

    @State private var status: CommandLineToolStatus = .notInstalled
    @State private var manualCommand: String?
    @State private var errorMessage: String?

    init(installer: CommandLineToolInstalling = CommandLineToolInstaller.shared) {
        self.installer = installer
    }

    var body: some View {
        Section {
            LabeledContent {
                switch status {
                case .notInstalled:
                    Button("Install") { install() }
                case .installed:
                    Button("Uninstall") { uninstall() }
                case .conflict:
                    Button("Install") { install() }
                        .disabled(true)
                }
            } label: {
                Text("tablepro command")
                Text(installer.toolPath)
                    .font(.system(.caption, design: .monospaced))
            }

            if let manualCommand {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TablePro could not do this for you. Run this in Terminal instead:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    CopyableCodeBlock(text: manualCommand)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Command Line")
        } footer: {
            Text("Opens database URLs from the terminal, such as a DDEV project database.")
        }
        .onAppear(perform: syncStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncStatus()
        }
    }

    private func syncStatus() {
        let updated = installer.status
        guard updated != status else { return }
        status = updated
        manualCommand = nil
        errorMessage = nil
    }

    private func install() {
        do {
            try installer.install()
            manualCommand = nil
            errorMessage = nil
        } catch CommandLineToolError.cancelled {
            manualCommand = nil
            errorMessage = nil
        } catch CommandLineToolError.conflict(let path) {
            manualCommand = nil
            errorMessage = CommandLineToolError.conflict(path).localizedDescription
        } catch {
            manualCommand = installer.manualInstallCommand
            errorMessage = error.localizedDescription
        }
        status = installer.status
    }

    private func uninstall() {
        do {
            try installer.uninstall()
            manualCommand = nil
            errorMessage = nil
        } catch CommandLineToolError.cancelled {
            manualCommand = nil
            errorMessage = nil
        } catch {
            manualCommand = installer.manualUninstallCommand
            errorMessage = error.localizedDescription
        }
        status = installer.status
    }
}
