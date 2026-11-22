//
//  TransportCommandRows.swift
//  TablePro
//

import SwiftUI

struct TransportCommandRow: View {
    let row: BuiltInRow
    @ObservedObject var store: ConnectionEditorStore

    private var editorRow: EditorRow { .builtIn(row) }

    var body: some View {
        switch row {
        case .tunnelCommandMethod:
            SSHAndProxiesPicker(
                String(localized: "Method"),
                selection: store.binding(\.tunnelCommand.config.method),
                row: editorRow,
                store: store
            ) {
                ForEach(TunnelCommandMethod.allCases) { method in
                    Text(method.displayName).tag(method)
                }
            }
        case .kubernetesResource:
            text(String(localized: "Resource"), \.tunnelCommand.config.kubernetesResource, prompt: "service/postgres")
        case .kubernetesNamespace:
            text(String(localized: "Namespace"), \.tunnelCommand.config.kubernetesNamespace, prompt: "production")
        case .kubernetesContext:
            text(String(localized: "Context"), \.tunnelCommand.config.kubernetesContext, prompt: String(localized: "Optional"))
        case .awsTarget:
            text(String(localized: "Target"), \.tunnelCommand.config.awsTarget, prompt: "i-0123456789abcdef0")
        case .awsProfile:
            text(String(localized: "Profile"), \.tunnelCommand.config.awsProfile, prompt: String(localized: "Optional"))
        case .awsRegion:
            text(String(localized: "Region"), \.tunnelCommand.config.awsRegion, prompt: String(localized: "Optional"))
        case .tunnelCommand:
            EditorCodeEditor(
                text: store.binding(\.tunnelCommand.config.command),
                language: .shell,
                row: editorRow,
                store: store,
                minHeight: 64
            )
        case .tunnelCommandExecutable:
            EditorPathRow(
                String(localized: "Executable Path"),
                path: store.binding(\.tunnelCommand.config.executablePath),
                prompt: executablePrompt,
                row: editorRow,
                store: store
            ) {
                await TransportFilePanel.chooseExecutable(currentPath: store.draft.tunnelCommand.config.executablePath, store: store)
            }
        case .tunnelCommandPreview:
            if let preview = store.tunnelCommandPreview {
                CodeWell(preview, font: .system(.body, design: .monospaced))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(editorRow.accessibilityIdentifier)
            }
        default:
            EmptyView()
        }
    }

    private var executablePrompt: String {
        switch store.draft.tunnelCommand.config.method {
        case .kubectl: return "/opt/homebrew/bin/kubectl"
        case .awsSSM: return "/usr/local/bin/aws"
        case .custom: return ""
        }
    }

    private func text(_ title: String, _ keyPath: WritableKeyPath<ConnectionDraft, String>, prompt: String) -> some View {
        EditorTextRow(title, text: store.binding(keyPath), prompt: prompt, row: editorRow, store: store)
    }
}
