//
//  ThemeStorage.swift
//  TablePro
//
//  File I/O for theme JSON files.
//  Built-in themes loaded from app bundle, user themes from Application Support.
//

import Foundation
import os

internal struct ThemeStorage {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeStorage")

    private static let userThemesDirectory: URL = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("TablePro/Themes", isDirectory: true)
        }
        return appSupport.appendingPathComponent("TablePro/Themes", isDirectory: true)
    }()

    private static let bundledThemesDirectory: URL? = {
        Bundle.main.resourceURL
    }()

    private static let registryThemesDirectory: URL = {
        userThemesDirectory.appendingPathComponent("Registry", isDirectory: true)
    }()

    private static func themeFileURL(in directory: URL, id: String) throws -> URL {
        let allowed = #"^[A-Za-z0-9._-]+$"#
        guard id.range(of: allowed, options: .regularExpression) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return directory.appendingPathComponent("\(id).json", isDirectory: false)
    }

    // MARK: - Load All Themes

    static func loadAllThemes() -> [ThemeDefinition] {
        var themes: [ThemeDefinition] = []

        // Load built-in themes from app bundle (files copied flat to Resources/)
        if let bundleDir = bundledThemesDirectory {
            themes.append(contentsOf: loadBuiltInThemes(from: bundleDir))
        }

        // If no bundled themes loaded, use compiled presets as fallback
        if themes.isEmpty {
            themes = [ThemeDefinition.default]
        }

        // Load registry themes
        ensureRegistryDirectory()
        themes.append(contentsOf: loadThemes(from: registryThemesDirectory, isBuiltIn: false))

        // Load user themes
        ensureUserDirectory()
        themes.append(contentsOf: loadThemes(from: userThemesDirectory, isBuiltIn: false))

        return themes
    }

    // MARK: - Load Single Theme

    static func loadTheme(id: String) -> ThemeDefinition? {
        guard let userFile = try? themeFileURL(in: userThemesDirectory, id: id) else { return nil }
        if let theme = loadTheme(from: userFile) {
            return theme
        }

        if let registryFile = try? themeFileURL(in: registryThemesDirectory, id: id),
           let theme = loadTheme(from: registryFile) {
            return theme
        }

        if let bundleDir = bundledThemesDirectory,
           let bundleFile = try? themeFileURL(in: bundleDir, id: id),
           let theme = loadTheme(from: bundleFile) {
            return theme
        }

        // Fallback to compiled presets
        return id == ThemeDefinition.default.id ? .default : nil
    }

    // MARK: - Save User Theme

    static func saveUserTheme(_ theme: ThemeDefinition) throws {
        ensureUserDirectory()
        let url = try themeFileURL(in: userThemesDirectory, id: theme.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(theme)
        try data.write(to: url, options: .atomic)
        logger.info("Saved user theme: \(theme.id)")
    }

    // MARK: - Delete User Theme

    static func deleteUserTheme(id: String) throws {
        let url = try themeFileURL(in: userThemesDirectory, id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        logger.info("Deleted user theme: \(id)")
    }

    // MARK: - Save Registry Theme

    static func saveRegistryTheme(_ theme: ThemeDefinition) throws {
        ensureRegistryDirectory()
        let url = try themeFileURL(in: registryThemesDirectory, id: theme.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(theme)
        try data.write(to: url, options: .atomic)
        logger.info("Saved registry theme: \(theme.id)")
    }

    // MARK: - Delete Registry Theme

    static func deleteRegistryTheme(id: String) throws {
        let url = try themeFileURL(in: registryThemesDirectory, id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        logger.info("Deleted registry theme: \(id)")
    }

    // MARK: - Registry Meta

    private static let registryMetaURL: URL = {
        registryThemesDirectory.appendingPathComponent("registry-meta.json")
    }()

    static func loadRegistryMeta() -> RegistryThemeMeta {
        guard FileManager.default.fileExists(atPath: registryMetaURL.path) else {
            return RegistryThemeMeta()
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: registryMetaURL)
            return try decoder.decode(RegistryThemeMeta.self, from: data)
        } catch {
            logger.error("Failed to load registry meta: \(error)")
            return RegistryThemeMeta()
        }
    }

    static func saveRegistryMeta(_ meta: RegistryThemeMeta) throws {
        ensureRegistryDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meta)
        try data.write(to: registryMetaURL, options: .atomic)
    }

    // MARK: - Import / Export

    static func importTheme(from sourceURL: URL) throws -> ThemeDefinition {
        let data = try Data(contentsOf: sourceURL)
        var theme = try JSONDecoder().decode(ThemeDefinition.self, from: data)

        // Avoid clobbering an existing theme on import
        if theme.isBuiltIn || theme.isRegistry || loadTheme(id: theme.id) != nil {
            theme.id = "user.\(UUID().uuidString.lowercased().prefix(8))"
        }

        try saveUserTheme(theme)
        return theme
    }

    static func exportTheme(_ theme: ThemeDefinition, to destinationURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(theme)
        try data.write(to: destinationURL, options: .atomic)
        logger.info("Exported theme: \(theme.id) to \(destinationURL.lastPathComponent)")
    }

    // MARK: - Helpers

    private static func ensureUserDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: userThemesDirectory.path) {
            do {
                try fm.createDirectory(at: userThemesDirectory, withIntermediateDirectories: true)
            } catch {
                logger.error("Failed to create user themes directory: \(error)")
            }
        }
    }

    private static func ensureRegistryDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: registryThemesDirectory.path) {
            do {
                try fm.createDirectory(at: registryThemesDirectory, withIntermediateDirectories: true)
            } catch {
                logger.error("Failed to create registry themes directory: \(error)")
            }
        }
    }

    private static let builtInThemeOrder = [
        "tablepro.default-light",
        "tablepro.default-dark",
        "tablepro.dracula",
        "tablepro.nord",
    ]

    private static func loadBuiltInThemes(from directory: URL) -> [ThemeDefinition] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        do {
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("tablepro.") }

            let themes = files.compactMap { loadTheme(from: $0) }
            return themes.sorted { lhs, rhs in
                let li = builtInThemeOrder.firstIndex(of: lhs.id) ?? Int.max
                let ri = builtInThemeOrder.firstIndex(of: rhs.id) ?? Int.max
                return li < ri
            }
        } catch {
            logger.error("Failed to list built-in themes: \(error)")
            return []
        }
    }

    private static func loadThemes(from directory: URL, isBuiltIn: Bool) -> [ThemeDefinition] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        do {
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && $0.lastPathComponent != "registry-meta.json" }

            return files.compactMap { loadTheme(from: $0) }
        } catch {
            logger.error("Failed to list themes in \(directory.lastPathComponent): \(error)")
            return []
        }
    }

    private static func loadTheme(from url: URL) -> ThemeDefinition? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ThemeDefinition.self, from: data)
        } catch {
            logger.error("Failed to load theme from \(url.lastPathComponent): \(error)")
            return nil
        }
    }
}
