//
//  SetupGuideView.swift
//  TablePro
//

import SwiftUI

// Buttons sit in a footer inside the content: a toolbar would bridge into the title bar.
internal struct SetupGuideView: View {
    @ObservedObject var model: SetupGuideModel

    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            heading
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(model.step)
                .transition(.opacity)
            if !model.isRunningImport {
                Divider()
                footer
            }
        }
        .motionAnimation(.easeInOut(duration: 0.2), value: model.step)
        .importSheetFrame()
        .onValueChange(of: model.step) { _, _ in
            headingFocused = true
            if #unavailable(macOS 14) {
                AccessibilityAnnouncement.post(Self.title(of: model.step))
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: Self.title(of: model.step))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
                .accessibilityIdentifier("setup-guide-heading")
            Text(verbatim: Self.subtitle(of: model.step))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .origin:
            SetupGuideOriginStep(model: model)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("setup-guide-step-origin")
        case .import:
            SetupGuideImportStep(model: model)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("setup-guide-step-import")
        case .firstConnection:
            SetupGuideFirstConnectionStep(model: model)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("setup-guide-step-first-connection")
        case .options:
            SetupGuideOptionsStep(model: model)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("setup-guide-step-options")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.canGoBack {
                Button(String(localized: "Back")) { model.back() }
                    .accessibilityIdentifier("setup-guide-back")
            }
            Spacer()
            Button(String(localized: "Skip")) { model.skip() }
                .accessibilityIdentifier("setup-guide-skip")
            Button(model.primaryTitle) { model.primary() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue)
                .accessibilityIdentifier("setup-guide-primary")
        }
        .padding(12)
        .focusSection()
    }

    private static func title(of step: SetupGuideStep) -> String {
        switch step {
        case .origin: String(localized: "Get Started")
        case .import: String(localized: "Import from Other Apps")
        case .firstConnection: String(localized: "First Connection")
        case .options: String(localized: "Appearance and Keys")
        }
    }

    private static func subtitle(of step: SetupGuideStep) -> String {
        switch step {
        case .origin:
            String(localized: "Start with a new connection or the sample database, or bring the connections you have.")
        case .import:
            String(localized: "Select the apps to import from. You review each one before anything is saved.")
        case .firstConnection:
            String(localized: "Choose what opens when you finish.")
        case .options:
            String(localized: "Changes apply now. You can change them later in Settings.")
        }
    }
}
