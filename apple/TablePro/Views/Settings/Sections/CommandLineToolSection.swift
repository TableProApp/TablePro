import AppKit
import SwiftUI

struct CommandLineToolPage: View {
    private let tool: CommandLineShim
    @ObservedObject private var visit: SettingsPaneVisit

    @State private var link: CommandLineToolLink?

    init(visit: SettingsPaneVisit, tool: CommandLineShim = CommandLineShim()) {
        self.tool = tool
        self._visit = ObservedObject(wrappedValue: visit)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if let link {
                        Text(link.statusText)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("command-line-status")
                    }
                } label: {
                    Text("tablepro command")
                    Text("Opens database URLs and files, runs queries and exports tables from the terminal. Run `tablepro help` to see every command.")
                }

                LabeledContent("Location") {
                    Text(verbatim: tool.linkPath)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let link {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(link.instruction)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let command = link.command {
                            CopyableCodeBlock(text: command)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.commandLineTool.pageIdentifier)
        .task(id: visit.count) { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    // The link changes from Terminal, so it is read on every show and every return to the app.
    private func refresh() {
        let status = tool.status()
        link = CommandLineToolLink(status: status, command: tool.command(for: status))
    }
}

private struct CommandLineToolLink: Equatable {
    let status: CommandLineShimStatus
    let command: String?

    var statusText: String {
        switch status {
        case .linked:
            String(localized: "Linked")
        case .notLinked:
            String(localized: "Not linked")
        case .otherFile:
            String(localized: "Another file is there")
        }
    }

    var instruction: String {
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
}
