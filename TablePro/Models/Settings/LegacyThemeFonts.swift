import Foundation
import os

/// Reads the `fonts` object out of the theme files TablePro 0.80 wrote, once, on the first launch
/// with no typography setting. It never writes a theme file.
internal enum LegacyThemeFonts {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LegacyThemeFonts")

    /// 0.80 drew whatever size the file stored inside these ranges, so the carried size is the
    /// one the user saw rather than the one zoom had stored.
    private static let renderedEditorSizes = 11...18
    private static let renderedDataGridSizes = 10...18

    private struct Document: Decodable {
        struct Fonts: Decodable {
            var editorFontFamily: String?
            var editorFontSize: Int?
            var dataGridFontFamily: String?
            var dataGridFontSize: Int?
        }

        var id: String?
        var fonts: Fonts?
    }

    internal static func read(
        appearance: AppearanceSettings,
        systemIsDark: Bool,
        themesDirectory: URL
    ) -> TypographySettings {
        let fontsById = loadFonts(in: themesDirectory)
        for id in candidateIds(appearance: appearance, systemIsDark: systemIsDark) {
            guard let fonts = fontsById[id] else { continue }
            return settings(from: fonts)
        }
        return .default
    }

    /// 0.80 applied the fonts of the theme on screen, so the slot of the appearance in effect
    /// comes first and the other slot only fills in when that theme carried none.
    internal static func candidateIds(appearance: AppearanceSettings, systemIsDark: Bool) -> [String] {
        let effective = ThemeResolver.effectiveAppearance(mode: appearance.appearanceMode, systemIsDark: systemIsDark)
        switch effective {
        case .light: return [appearance.preferredLightThemeId, appearance.preferredDarkThemeId]
        case .dark: return [appearance.preferredDarkThemeId, appearance.preferredLightThemeId]
        }
    }

    /// Keyed by the `id` inside each file, not the file name: an exported theme the user copied in
    /// keeps the name they gave it.
    private static func loadFonts(in directory: URL) -> [String: Document.Fonts] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return [:]
        }

        var fontsById: [String: Document.Fonts] = [:]
        for file in files {
            do {
                let document = try JSONDecoder().decode(Document.self, from: try Data(contentsOf: file))
                guard let fonts = document.fonts else { continue }
                let id = document.id ?? file.deletingPathExtension().lastPathComponent
                if fontsById[id] == nil {
                    fontsById[id] = fonts
                }
            } catch {
                logger.error("Could not read legacy fonts from \(file.lastPathComponent): \(error.publicLogShape, privacy: .public)")
            }
        }
        return fontsById
    }

    private static func settings(from fonts: Document.Fonts) -> TypographySettings {
        let fallback = TypographySettings.default
        return TypographySettings(
            editorFontFamily: fonts.editorFontFamily ?? fallback.editorFontFamily,
            editorFontSize: rendered(fonts.editorFontSize ?? fallback.editorFontSize, in: renderedEditorSizes),
            dataGridFontFamily: fonts.dataGridFontFamily ?? fallback.dataGridFontFamily,
            dataGridFontSize: rendered(fonts.dataGridFontSize ?? fallback.dataGridFontSize, in: renderedDataGridSizes)
        )
    }

    private static func rendered(_ size: Int, in range: ClosedRange<Int>) -> Int {
        TypographySettings.clamp(min(max(size, range.lowerBound), range.upperBound))
    }
}
