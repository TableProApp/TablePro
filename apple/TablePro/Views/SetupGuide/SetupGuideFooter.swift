import AppKit
import SwiftUI

internal struct SetupGuideFooter: View {
    @ObservedObject var model: SetupGuideModel

    private enum Mode {
        case steps
        case pickingFile(ForeignSourceRow)
        case reading
        case sheet
    }

    private var mode: Mode {
        guard model.step == .import else { return .steps }
        switch model.importPhase {
        case .scanning, .choosing: return .steps
        case .pickingFile(let row): return .pickingFile(row)
        case .reading: return .reading
        case .notice, .review: return .sheet
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            leading
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .motionAnimation(.easeInOut(duration: 0.2), value: model.canGoBack)
        .focusSection()
    }

    @ViewBuilder
    private var leading: some View {
        if case .steps = mode, model.canGoBack {
            Button { model.back() } label: {
                label(String(localized: "Back"))
            }
            .modifier(FooterButtonStyle(isProminent: false))
            .transition(.opacity)
            .accessibilityIdentifier("setup-guide-back")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch mode {
        case .steps:
            skipButton
            primaryButton
        case .sheet:
            skipButton
                .disabled(true)
            primaryButton
                .disabled(true)
        case .pickingFile(let row):
            Button { model.skipCurrentSource() } label: {
                label(String(localized: "Skip This App"))
            }
            .modifier(FooterButtonStyle(isProminent: false))
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("setup-guide-skip-app")
            Button { chooseFile(for: row) } label: {
                label(String(localized: "Choose File…"))
            }
            .modifier(FooterButtonStyle(isProminent: true))
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("setup-guide-choose-file")
        case .reading:
            Button { model.skipCurrentSource() } label: {
                label(String(localized: "Cancel"))
            }
            .modifier(FooterButtonStyle(isProminent: false))
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("setup-guide-reading-cancel")
        }
    }

    private var skipButton: some View {
        Button { model.skip() } label: {
            label(String(localized: "Skip"))
        }
        .modifier(FooterButtonStyle(isProminent: false))
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("setup-guide-skip")
    }

    private var primaryButton: some View {
        Button { model.primary() } label: {
            label(model.primaryTitle)
                .contentTransition(.numericText())
                .motionAnimation(.easeInOut(duration: 0.2), value: model.primaryTitle)
        }
        .modifier(FooterButtonStyle(isProminent: true))
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("setup-guide-primary")
    }

    private func label(_ title: String) -> some View {
        Text(verbatim: title)
            .frame(minWidth: 96)
    }

    private func chooseFile(for row: ForeignSourceRow) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let types = row.importer.importFileTypes {
            panel.allowedContentTypes = types
        }
        panel.message = String(format: String(localized: "Choose a %@ export file to import"), row.importer.displayName)
        panel.presentAsSheet(for: NSApp.keyWindow) { url in
            guard let url else { return }
            model.fileChosen(url)
        }
    }
}

// Liquid Glass belongs on controls, so the footer is the one place the guide uses it.
private struct FooterButtonStyle: ViewModifier {
    let isProminent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if isProminent {
                content.buttonStyle(.glassProminent).controlSize(.extraLarge)
            } else {
                content.buttonStyle(.glass).controlSize(.extraLarge)
            }
        } else if isProminent {
            content.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            content.buttonStyle(.bordered).controlSize(.large)
        }
    }
}
