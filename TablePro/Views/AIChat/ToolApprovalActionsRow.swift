//
//  ToolApprovalActionsRow.swift
//  TablePro
//

import SwiftUI

struct ToolApprovalActionsRow: View {
    let toolUseId: String
    let toolName: String

    var body: some View {
        HStack(spacing: 8) {
            Button {
                ToolApprovalCenter.shared.resolve(toolUseId: toolUseId, decision: .run)
            } label: {
                Text(String(localized: "Run"))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)

            Button {
                ToolApprovalCenter.shared.resolve(toolUseId: toolUseId, decision: .alwaysAllow)
            } label: {
                Text(String(localized: "Always for this connection"))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(String(format: String(localized: "Always allow %@ for this connection"), toolName))

            Button {
                ToolApprovalCenter.shared.resolve(toolUseId: toolUseId, decision: .cancel)
            } label: {
                Text(String(localized: "Cancel"))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)

            Spacer()
        }
        .padding(.top, 2)
    }
}
