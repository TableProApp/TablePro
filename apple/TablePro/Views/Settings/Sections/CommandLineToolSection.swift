import AppKit
import SwiftUI

struct CommandLineToolSection: View {
    private let tool: CommandLineShim

    @State private var status: CommandLineShimStatus = .notLinked
    @State private var command: String?

    init(tool: CommandLineShim = CommandLineShim()) {
        self.tool = tool
        _command = State(initialValue: tool.linkCommand)
    }

    var body: some View {
        Section {
            LabeledContent {
                Text(statusText)
                    .foregroundStyle(.secondary)
            } label: {
                Text("tablepro command")
                Text(tool.linkPath)
                    .font(.system(.caption, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(instruction)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let command {
                    CopyableCodeBlock(text: command)
                }
            }
        } header: {
            Text("Command Line")
        } footer: {
            Text("Opens database URLs and files, runs queries and exports tables from the terminal. Run `tablepro help` to see every command.")
        }
        .onAppear(perform: syncStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncStatus()
        }
    }

    private var statusText: String {
        switch status {
        case .linked:
            String(localized: "Linked")
        case .notLinked:
            String(localized: "Not linked")
        case .otherFile:
            String(localized: "Another file is there")
        }
    }

    private var instruction: String {
        guard command != nil else {
            return String(localized: "TablePro is running from a disk image or a temporary location. Move it to the Applications folder first, then open it from there.")
        }
        switch status {
        case .linked:
            return String(localized: "To remove it, run this in Terminal:")
        case .notLinked:
            return String(localized: "To add it to your PATH, run this in Terminal:")
        case .otherFile:
            return String(localized: "To replace that file with a link to this app, run this in Terminal:")
        }
    }

    private func syncStatus() {
        status = tool.status()
        command = tool.command(for: status)
    }
}
