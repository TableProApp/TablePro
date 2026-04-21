//
//  TerminalSettingsView.swift
//  TablePro
//

import GhosttyTheme
import SwiftUI

struct TerminalSettingsView: View {
    @Binding var settings: TerminalSettings

    private static let monospaceFonts = [
        "Menlo", "SF Mono", "Monaco", "Courier New", "JetBrains Mono",
        "Fira Code", "Source Code Pro", "Hack", "Inconsolata"
    ]

    private static let scrollbackOptions: [(String, Int)] = [
        ("1,000", 1_000),
        ("5,000", 5_000),
        ("10,000", 10_000),
        ("50,000", 50_000),
        ("Unlimited", 0)
    ]

    private static let terminalDatabaseTypes: [DatabaseType] = [
        .mysql, .mariadb, .postgresql, .redshift, .redis, .mongodb,
        .sqlite, .mssql, .clickhouse, .duckdb, .oracle
    ]

    var body: some View {
        Form {
            displaySection
            themeSection
            cliPathsSection
            notificationsSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Display

    @ViewBuilder
    private var displaySection: some View {
        Section("Display") {
            Picker("Font:", selection: $settings.fontFamily) {
                ForEach(Self.availableFonts, id: \.self) { font in
                    Text(font).tag(font)
                }
            }

            Picker("Font size:", selection: $settings.fontSize) {
                ForEach(9 ... 24, id: \.self) { size in
                    Text("\(size)").tag(size)
                }
            }

            Picker("Cursor style:", selection: $settings.cursorStyle) {
                ForEach(TerminalCursorStyleOption.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }

            Toggle("Cursor blink", isOn: $settings.cursorBlink)

            Picker("Scrollback lines:", selection: $settings.scrollbackLines) {
                ForEach(Self.scrollbackOptions, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }

            Toggle("Option as Meta key", isOn: $settings.optionAsMeta)
        }
    }

    // MARK: - Theme

    @ViewBuilder
    private var themeSection: some View {
        Section("Theme") {
            Picker("Theme:", selection: $settings.themeName) {
                Text("Default").tag("")
                ForEach(GhosttyThemeCatalog.allThemes) { theme in
                    HStack(spacing: 6) {
                        Text(theme.name)
                        Spacer()
                        themeSwatches(theme)
                    }
                    .tag(theme.name)
                }
            }
        }
    }

    @ViewBuilder
    private func themeSwatches(_ theme: GhosttyThemeDefinition) -> some View {
        HStack(spacing: 2) {
            colorSwatch(hex: theme.background)
            colorSwatch(hex: theme.foreground)
            if let cursor = theme.cursorColor {
                colorSwatch(hex: cursor)
            }
        }
    }

    @ViewBuilder
    private func colorSwatch(hex: String) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(hex.swiftUIColor)
            .frame(width: 12, height: 12)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
    }

    // MARK: - CLI Paths

    @State private var resolvedPaths: [String: String] = [:]

    @ViewBuilder
    private var cliPathsSection: some View {
        Section {
            ForEach(Self.terminalDatabaseTypes, id: \.rawValue) { dbType in
                cliPathRow(for: dbType)
            }
        } header: {
            Text("CLI Paths")
        } footer: {
            Text("Leave empty to auto-detect from system PATH.")
        }
        .task {
            await resolveAllCliPaths()
        }
    }

    @ViewBuilder
    private func cliPathRow(for dbType: DatabaseType) -> some View {
        let binding = Binding<String>(
            get: { settings.cliPaths[dbType.rawValue] ?? "" },
            set: { settings.cliPaths[dbType.rawValue] = $0.isEmpty ? nil : $0 }
        )
        let binaryName = CLICommandResolver.binaryName(for: dbType)
        let placeholder = resolvedPaths[dbType.rawValue] ?? binaryName

        LabeledContent(dbType.displayName) {
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
        }
    }

    private func resolveAllCliPaths() async {
        let dbTypes = Self.terminalDatabaseTypes
        let results = await withTaskGroup(of: (String, String).self) { group in
            for dbType in dbTypes {
                group.addTask {
                    let name = CLICommandResolver.binaryName(for: dbType)
                    let resolved = await Task.detached(priority: .utility) {
                        CLICommandResolver.findExecutable(name)
                    }.value
                    return (dbType.rawValue, resolved ?? name)
                }
            }
            var paths: [String: String] = [:]
            for await (key, value) in group {
                paths[key] = value
            }
            return paths
        }
        resolvedPaths = results
    }

    // MARK: - Notifications

    @ViewBuilder
    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Terminal bell", isOn: $settings.bellEnabled)
        }
    }

    // MARK: - Helpers

    private static var availableFonts: [String] {
        let available = Set(
            NSFontManager.shared.availableFontFamilies
        )
        return monospaceFonts.filter { available.contains($0) }
    }
}


#Preview {
    TerminalSettingsView(settings: .constant(.default))
        .frame(width: 600, height: 500)
}
