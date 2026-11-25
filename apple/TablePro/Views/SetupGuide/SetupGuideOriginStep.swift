//
//  SetupGuideOriginStep.swift
//  TablePro
//

import SwiftUI

internal struct SetupGuideOriginStep: View {
    @ObservedObject var model: SetupGuideModel

    private static let starts: [SetupGuideOrigin] = [.newConnection, .sample]

    var body: some View {
        List(selection: selection) {
            Section(String(localized: "Start Fresh")) {
                ForEach(Self.starts, id: \.self) { origin in
                    row(origin)
                }
            }
            Section(String(localized: "Bring Your Connections")) {
                ForEach(ImportCommand.allCases, id: \.self) { command in
                    row(.command(command))
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: SetupGuideOrigin.self, menu: { _ in EmptyView() }, primaryAction: { _ in
            model.primary()
        })
        .accessibilityLabel(String(localized: "How to start"))
    }

    private var selection: Binding<SetupGuideOrigin?> {
        Binding(
            get: { model.origin },
            set: { chosen in
                // Only a change counts as the user's choice; the probe still decides while the default stands.
                if let chosen, chosen != model.origin {
                    model.origin = chosen
                }
            }
        )
    }

    private func row(_ origin: SetupGuideOrigin) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.symbol(for: origin))
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.title(for: origin))
                Text(verbatim: Self.detail(for: origin))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup-guide-origin-\(Self.identifier(for: origin))")
        .tag(origin)
    }

    private static func title(for origin: SetupGuideOrigin) -> String {
        switch origin {
        case .command(let command): command.title
        case .newConnection: String(localized: "New Connection")
        case .sample: String(localized: "Sample Database")
        }
    }

    private static func detail(for origin: SetupGuideOrigin) -> String {
        switch origin {
        case .command(.connectionsFile): String(localized: "A file exported from TablePro")
        case .command(.url): String(localized: "A connection URL you paste")
        case .command(.otherApp): String(localized: "Connections saved by another database app on this Mac")
        case .command(.aws): String(localized: "Databases in your AWS account")
        case .command(.projectFolder): String(localized: "Settings found in a project's files")
        case .newConnection: String(localized: "Enter the details of your own database")
        case .sample: String(localized: "A small SQLite database to look around in")
        }
    }

    private static func symbol(for origin: SetupGuideOrigin) -> String {
        switch origin {
        case .command(.connectionsFile): "doc"
        case .command(.url): "link"
        case .command(.otherApp): "square.and.arrow.down.on.square"
        case .command(.aws): "cloud"
        case .command(.projectFolder): "folder"
        case .newConnection: "plus.circle"
        case .sample: "cylinder.split.1x2"
        }
    }

    private static func identifier(for origin: SetupGuideOrigin) -> String {
        switch origin {
        case .command(.connectionsFile): "file"
        case .command(.url): "url"
        case .command(.otherApp): "other-app"
        case .command(.aws): "aws"
        case .command(.projectFolder): "project-folder"
        case .newConnection: "new-connection"
        case .sample: "sample"
        }
    }
}
