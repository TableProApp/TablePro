//
//  TerminalErrorView.swift
//  TablePro
//

import SwiftUI

struct TerminalErrorView: View {
    let error: String
    let databaseType: DatabaseType

    var body: some View {
        ContentUnavailableView {
            Label("Terminal Unavailable", systemImage: "terminal")
        } description: {
            Text(error)
        } actions: {
            let instructions = CLICommandResolver.installInstructions(for: databaseType)
            Text(instructions)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
