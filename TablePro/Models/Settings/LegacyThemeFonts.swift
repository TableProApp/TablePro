import Foundation
import os

/// Reads the `fonts` object out of a theme file written before fonts moved into settings. It is
/// the only code that still opens the old format, it runs once, and it writes nothing back: the
/// theme file keeps its own shape and is rejected by the current loader like any other old file.
internal enum LegacyThemeFonts {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LegacyThemeFonts")

    private struct Document: Decodable {
        struct Fonts: Decodable {
            var editorFontFamily: String?
            var editorFontSize: Int?
            var dataGridFontFamily: String?
            var dataGridFontSize: Int?
        }

        var fonts: Fonts?
    }

    internal static func read(preferring appearance: AppearanceSettings) -> TypographySettings {
        let candidates = [appearance.preferredLightThemeId, appearance.preferredDarkThemeId]

        for id in candidates {
            guard let fonts = fonts(forThemeId: id) else { continue }
            return settings(from: fonts)
        }

        return .default
    }

    private static func fonts(forThemeId id: String) -> Document.Fonts? {
        let directories = [userThemesDirectory, userThemesDirectory.appendingPathComponent("Registry")]
            + (Bundle.main.resourceURL.map { [$0] } ?? [])

        for directory in directories {
            let url = directory.appendingPathComponent("\(id).json", isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            do {
                let document = try JSONDecoder().decode(Document.self, from: try Data(contentsOf: url))
                guard let fonts = document.fonts else { continue }
                return fonts
            } catch {
                logger.error("Could not read legacy fonts from \(url.lastPathComponent): \(error)")
            }
        }

        return nil
    }

    private static func settings(from fonts: Document.Fonts) -> TypographySettings {
        let fallback = TypographySettings.default

        return TypographySettings(
            editorFontFamily: fonts.editorFontFamily ?? fallback.editorFontFamily,
            editorFontSize: TypographySettings.clamp(fonts.editorFontSize ?? fallback.editorFontSize),
            dataGridFontFamily: fonts.dataGridFontFamily ?? fallback.dataGridFontFamily,
            dataGridFontSize: TypographySettings.clamp(fonts.dataGridFontSize ?? fallback.dataGridFontSize)
        )
    }

    private static var userThemesDirectory: URL {
        AppStorageEnvironment.shared.applicationSupportRoot
            .appendingPathComponent("TablePro/Themes", isDirectory: true)
    }
}
