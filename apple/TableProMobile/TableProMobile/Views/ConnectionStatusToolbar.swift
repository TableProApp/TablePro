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

    // A session that is gone; reached only under unsaved edits, which keep the tabs up in place of the error view.
    private var reconnectSymbol: String? {
        guard isEnabled, progressTitle == nil else { return nil }
        return presentation.symbol?.systemName
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // The bottom toolbar sits under the floating tab bar, so the state goes under the title, as Mail's does.
            content
                .navigationSubtitle(Text(verbatim: subtitle ?? ""))
                .toolbar {
                    // A bar item shows a label's icon alone, so the action reads as text beside the subtitle's state.
                    if reconnectSymbol != nil, let help = presentation.help {
                        ToolbarItem(placement: .topBarTrailing) {
                            reconnectButton(symbol: nil, help: help)
                        }
                    }
                }
        } else {
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
                } else if let symbol = reconnectSymbol, let help = presentation.help {
                    ToolbarItem(placement: .status) {
                        reconnectButton(symbol: symbol, help: help)
                    }
                }
            }
        }
    }

    private var subtitle: String? {
        guard isEnabled else { return nil }
        if let progressTitle { return progressTitle }
        return reconnectSymbol == nil ? nil : presentation.title
    }

    private func reconnectButton(symbol: String?, help: String) -> some View {
        Button {
            Task { await coordinator.reconnect() }
        } label: {
            if let symbol {
                Label(String(localized: "Reconnect"), systemImage: symbol)
                    .labelStyle(.titleAndIcon)
            } else {
                Text(String(localized: "Reconnect"))
            }
        }
        .tint(presentation.tint.color)
        .help(help)
        .accessibilityValue(Text(help))
    }
}
