//
//  TerminalErrorView.swift
//  TablePro
//
//  Displayed when the CLI binary for a database connection cannot be found.
//  Shows the error message and installation instructions.
//

import SwiftUI

struct TerminalErrorView: View {
    let error: String
    let databaseType: DatabaseType

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Terminal Unavailable")
                .font(.title2)
                .fontWeight(.semibold)

            Text(error)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                Text("Install with:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                let instructions = CLICommandResolver.installInstructions(for: databaseType)
                Text(instructions)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
