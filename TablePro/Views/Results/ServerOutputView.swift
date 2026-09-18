//
//  ServerOutputView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// What a statement printed on the server, such as Oracle's `DBMS_OUTPUT`, as selectable text.
struct ServerOutputView: View {
    let output: PluginServerOutput

    private var text: String {
        output.lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Output")
                    .font(.headline)
                Text("^[\(output.lines.count) line](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(String(localized: "Copy Output"), systemImage: "doc.on.doc", action: copyOutput)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(String(localized: "Copy Output"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ServerOutputTextView(text: text)
            if output.isTruncated {
                Divider()
                Text("The output was cut short.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
    }

    private func copyOutput() {
        ClipboardService.shared.writeText(text)
    }
}

#Preview {
    ServerOutputView(output: PluginServerOutput(
        lines: ["Hello from PL/SQL", "", "rows processed: 42"],
        isTruncated: true
    ))
    .frame(width: 480, height: 240)
}
