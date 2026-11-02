import SwiftUI
import TableProConnectionLibrary

extension View {
    // Only what is in progress or wrong shows: a redial, a database or schema switch, or a session that is gone.
    @ViewBuilder
    func connectionStatusToolbar(for coordinator: ConnectionCoordinator?, isEnabled: Bool = true) -> some View {
        if let coordinator {
            modifier(ConnectionStatusToolbar(coordinator: coordinator, isEnabled: isEnabled))
        } else {
            self
        }
    }
}

private struct ConnectionStatusToolbar: ViewModifier {
    let coordinator: ConnectionCoordinator
    let isEnabled: Bool

    private var presentation: ConnectionStatusPresentation {
        ConnectionStatusPresentation(coordinator.displayStatus)
    }

    private var progressTitle: String? {
        if let target = coordinator.switchTarget {
            return String(format: String(localized: "Switching to %@…"), target)
        }
        return presentation.isBusy ? presentation.title : nil
    }

    func body(content: Content) -> some View {
        content.toolbar {
            if isEnabled, let progressTitle {
                ToolbarItem(placement: .status) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(progressTitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(progressTitle))
                }
            } else if isEnabled, let symbol = presentation.symbol?.systemName, let help = presentation.help {
                // Reached only under unsaved edits, which keep the tabs on screen in place of the error view.
                ToolbarItem(placement: .status) {
                    Button {
                        Task { await coordinator.reconnect() }
                    } label: {
                        Label(String(localized: "Reconnect"), systemImage: symbol)
                            .labelStyle(.titleAndIcon)
                    }
                    .tint(presentation.tint.color)
                    .help(help)
                    .accessibilityValue(Text(help))
                }
            }
        }
    }
}
