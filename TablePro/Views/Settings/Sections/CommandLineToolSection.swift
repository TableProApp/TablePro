//
//  CommandLineToolSection.swift
//  TablePro
//

import AppKit
import SwiftUI

struct CommandLineToolSection: View {
    private let tool: CommandLineShim

    @State private var status: CommandLineShimStatus = .notLinked

    init(tool: CommandLineShim = CommandLineShim()) {
        self.tool = tool
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

                CopyableCodeBlock(text: status == .linked ? tool.unlinkCommand : tool.linkCommand)
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
        switch status {
        case .linked:
            String(localized: "To remove it, run this in Terminal:")
        case .notLinked:
            String(localized: "To add it to your PATH, run this in Terminal:")
        case .otherFile:
            String(localized: "To replace that file with a link to this app, run this in Terminal:")
        }
    }

    private func syncStatus() {
        status = tool.status()
    }
}
