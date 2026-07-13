//
//  CommandLineToolSection.swift
//  TablePro
//

import SwiftUI

struct CommandLineToolSection: View {
    private let installer: CommandLineToolInstalling

    @State private var status: CommandLineToolStatus = .notInstalled
    @State private var manualCommand: String?

    init(installer: CommandLineToolInstalling = CommandLineToolInstaller.shared) {
        self.installer = installer
    }

    var body: some View {
        Section {
            LabeledContent(installer.toolPath) {
                switch status {
                case .notInstalled:
                    Button("Install") { install() }
                case .installed:
                    Button("Uninstall") { uninstall() }
                case .conflict:
                    Text("A different file already exists here.")
                        .foregroundStyle(.secondary)
                }
            }

            if let manualCommand {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This folder is not writable. Run this command in Terminal, then reopen Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 8) {
                        Text(manualCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Copy") {
                            ClipboardService.shared.writeText(manualCommand)
                        }
                    }
                }
            }
        } header: {
            Text("Command Line")
        } footer: {
            Text("Adds a tablepro command that opens database URLs from the terminal, such as a DDEV project database.")
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        status = installer.status
    }

    private func install() {
        do {
            try installer.install()
            manualCommand = nil
        } catch CommandLineToolError.conflict {
            manualCommand = nil
        } catch {
            manualCommand = installer.manualInstallCommand
        }
        refresh()
    }

    private func uninstall() {
        try? installer.uninstall()
        manualCommand = nil
        refresh()
    }
}
