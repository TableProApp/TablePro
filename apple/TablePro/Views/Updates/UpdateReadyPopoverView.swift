import SwiftUI

struct UpdateReadyPopoverView: View {
    let status: UpdateStatus
    let onLater: () -> Void
    let onRelaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(status.readyTitle)
                    .font(.headline)
                Text(status.readyMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let url = status.readyAppRelease?.releaseNotesURL {
                Link(String(localized: "Release Notes"), destination: url)
            }

            if !status.stagedPlugins.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if let header = status.stagedPluginsHeader {
                        Text(header)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(status.stagedPlugins, id: \.self) { plugin in
                        Text(plugin.displayName)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("update-ready-plugins")
            }

            HStack {
                Spacer()
                Button(String(localized: "Later"), action: onLater)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Relaunch Now"), action: onRelaunch)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("update-ready-relaunch")
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }
}
