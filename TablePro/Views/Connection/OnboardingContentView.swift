//
//  OnboardingContentView.swift
//  TablePro
//
//  First-launch onboarding walkthrough with welcome branding,
//  feature highlights, and get started page.
//

import AppKit
import SwiftUI

struct OnboardingContentView: View {
    @State private var currentPage = 0
    @State private var navigatingForward = true

    var onComplete: () -> Void

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: navigatingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: navigatingForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main content area
            ZStack {
                switch currentPage {
                case 0:
                    welcomePage
                        .transition(pageTransition)
                case 1:
                    featuresPage
                        .transition(pageTransition)
                default:
                    getStartedPage
                        .transition(pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        if horizontal < -30, currentPage < 2 {
                            goToPage(currentPage + 1)
                        } else if horizontal > 30, currentPage > 0 {
                            goToPage(currentPage - 1)
                        }
                    }
            )

            // Bottom navigation bar
            navigationBar
        }
        .onKeyPress(.leftArrow) {
            guard currentPage > 0 else { return .ignored }
            goToPage(currentPage - 1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard currentPage < 2 else { return .ignored }
            goToPage(currentPage + 1)
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "h"), phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.control), currentPage > 0 else { return .ignored }
            goToPage(currentPage - 1)
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "l"), phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.control), currentPage < 2 else { return .ignored }
            goToPage(currentPage + 1)
            return .handled
        }
    }

    private func goToPage(_ page: Int) {
        navigatingForward = page > currentPage
        withAnimation(.easeInOut(duration: 0.35)) {
            currentPage = page
        }
    }

    // MARK: - Welcome Page

    private var welcomePage: some View {
        VStack(spacing: ThemeEngine.shared.activeTheme.spacing.md) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text("Welcome to TablePro")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("A fast, lightweight native macOS database client")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Features Page

    private var featuresPage: some View {
        VStack(spacing: ThemeEngine.shared.activeTheme.spacing.xl) {
            Text("What you can do")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.title2, weight: .semibold))

            VStack(alignment: .leading, spacing: 16) {
                featureRow(
                    icon: "cylinder.split.1x2",
                    title: String(localized: "MySQL, PostgreSQL & SQLite"),
                    description: String(localized: "Connect to popular databases with full feature support")
                )
                featureRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: String(localized: "Smart SQL Editor"),
                    description: String(localized: "Syntax highlighting, autocomplete, and multi-tab editing")
                )
                featureRow(
                    icon: "tablecells",
                    title: String(localized: "Interactive Data Grid"),
                    description: String(localized: "Browse, edit, and manage your data with ease")
                )
                featureRow(
                    icon: "lock.shield",
                    title: String(localized: "Secure Connections"),
                    description: String(localized: "SSH tunneling and SSL/TLS encryption support")
                )
                featureRow(
                    icon: "brain",
                    title: String(localized: "AI-Powered Assistant"),
                    description: String(localized: "Get intelligent SQL suggestions and query assistance")
                )
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: 420)
        }
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.extraLarge))
                .foregroundStyle(.tint)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: ThemeEngine.shared.activeTheme.spacing.xxxs) {
                Text(title)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .medium))
                Text(description)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Get Started Page

    private var getStartedPage: some View {
        VStack(spacing: ThemeEngine.shared.activeTheme.spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're all set!")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Text("Create a connection to get started with\nyour databases.")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack {
            Button("Skip") {
                completeOnboarding()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(currentPage == 2 ? 0 : 1)
            .frame(minWidth: 110, alignment: .leading)

            Spacer()

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i == currentPage ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 8, height: 8)
                        .scaleEffect(i == currentPage ? 1.2 : 1.0)
                        .onTapGesture { goToPage(i) }
                }
            }
            .animation(.spring(response: 0.3), value: currentPage)

            Spacer()

            ZStack {
                if currentPage < 2 {
                    Button("Continue") {
                        goToPage(currentPage + 1)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .transition(.opacity)
                } else {
                    Button("Get Started") {
                        completeOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: currentPage)
            .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.horizontal, ThemeEngine.shared.activeTheme.spacing.xl)
        .padding(.bottom, ThemeEngine.shared.activeTheme.spacing.lg)
    }

    // MARK: - Actions

    private func completeOnboarding() {
        AppSettingsStorage.shared.setOnboardingCompleted()
        onComplete()
    }
}

#Preview("Onboarding") {
    OnboardingContentView(onComplete: {})
}
