import Foundation

internal struct VSCodeThemeSource: Equatable, Sendable {
    internal var name: String?
    internal var author: String?
    internal var typeName: String?
    internal var colors: [String: ThemeColor] = [:]
    // In file order, includes first, as VS Code collects them. Filtering happens where they are read.
    internal var tokenRules: [VSCodeThemeValue] = []
}

// colorThemeData.ts _loadColorTheme and _loadSyntaxTokens, and themeCompatibility.ts convertSettings,
// plus the limits an untrusted file needs. VS Code has none of them because it trusts extensions.
// Every file the theme names must sit in the chosen file's folder, after symlinks are resolved.
internal struct VSCodeThemeLoader {
    // Real themes nest at most 3 levels: Dark Modern, Dark+, Dark (Visual Studio).
    internal static let maximumIncludeDepth = 8

    // themeCompatibility.ts settingToColorIdMapping, for the colors a slot reads.
    private static let globalSettingColors: [String: String] = [
        "background": "editor.background",
        "foreground": "editor.foreground",
        "selection": "editor.selectionBackground",
        "lineHighlight": "editor.lineHighlightBackground",
        "rangeHighlight": "editor.rangeHighlightBackground",
        "caret": "editorCursor.foreground",
        "invisibles": "editorWhitespace.foreground",
    ]

    private let fileURL: URL
    private let folder: URL

    internal init(fileURL: URL) {
        self.fileURL = fileURL
        folder = fileURL.deletingLastPathComponent().resolvingSymlinksInPath()
    }

    internal func load(root: [String: VSCodeThemeValue]) throws -> VSCodeThemeSource {
        var source = VSCodeThemeSource(
            name: root["name"]?.stringValue,
            author: root["author"]?.stringValue,
            typeName: root["type"]?.stringValue
        )
        var visited: Set<String> = [fileURL.resolvingSymlinksInPath().path]
        try apply(root, directory: folder, depth: 0, visited: &visited, to: &source)
        return source
    }

    private func apply(
        _ theme: [String: VSCodeThemeValue],
        directory: URL,
        depth: Int,
        visited: inout Set<String>,
        to source: inout VSCodeThemeSource
    ) throws {
        if let include = theme["include"], include.isTruthy {
            guard let path = include.stringValue else { throw ThemeLoadError.notATheme }
            try loadInclude(path, from: directory, depth: depth + 1, visited: &visited, into: &source)
        }

        // The legacy shape: a tmTheme's settings inline, and nothing else in the file is read.
        if let settings = theme["settings"]?.arrayValue {
            convertSettings(settings, into: &source)
            return
        }

        if let colors = theme["colors"], colors.isTruthy {
            switch colors {
            case let .object(entries):
                merge(entries, into: &source)
            case .array:
                // JavaScript accepts an array as an object here; no color id is an index.
                break
            default:
                throw ThemeLoadError.invalidColorMap
            }
        }

        if let tokenColors = theme["tokenColors"], tokenColors.isTruthy {
            switch tokenColors {
            case let .array(rules):
                source.tokenRules.append(contentsOf: rules)
            case let .string(path):
                try loadTextMateTheme(at: try containedFile(path, from: directory), named: path, into: &source)
            default:
                throw ThemeLoadError.invalidTokenColors
            }
        }
    }

    private func merge(_ entries: [String: VSCodeThemeValue], into source: inout VSCodeThemeSource) {
        for (key, value) in entries {
            guard let raw = value.stringValue else { continue }
            // "default" drops what an include set. VS Code paints an unparseable color red over the
            // included one; here the slot moves on to its next source instead.
            source.colors[key] = raw == "default" ? nil : VSCodeColorSyntax.color(raw)
        }
    }

    private func loadInclude(
        _ path: String,
        from directory: URL,
        depth: Int,
        visited: inout Set<String>,
        into source: inout VSCodeThemeSource
    ) throws {
        guard depth <= Self.maximumIncludeDepth else {
            throw ThemeLoadError.includeTooDeep(limit: Self.maximumIncludeDepth)
        }
        let url = try containedFile(path, from: directory)
        guard visited.insert(url.path).inserted else { throw ThemeLoadError.includeCycle(path) }

        guard url.pathExtension.lowercased() == "json" else {
            try loadTextMateTheme(at: url, named: path, into: &source)
            return
        }

        let value: VSCodeThemeValue
        do {
            value = try VSCodeThemeValue.parse(try ThemeFileImporter.contents(of: url))
        } catch let ThemeLoadError.malformedJSON(detail) {
            throw ThemeLoadError.malformedJSON(detail: [path, detail].compactMap { $0 }.joined(separator: ": "))
        }
        guard let theme = value.objectValue else { throw ThemeLoadError.notATheme }
        try apply(theme, directory: url.deletingLastPathComponent(), depth: depth, visited: &visited, to: &source)
    }

    // XML only, as VS Code reads it: a binary property list can share one container between many
    // parents, so a few hundred bytes can stand for a tree of billions of values.
    private func loadTextMateTheme(at url: URL, named path: String, into source: inout VSCodeThemeSource) throws {
        let data = try ThemeFileImporter.contents(of: url)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard
            let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
            format == .xml,
            let settings = VSCodeThemeValue(propertyList: propertyList)?.objectValue?["settings"]?.arrayValue
        else {
            throw ThemeLoadError.invalidTextMateTheme(path)
        }
        convertSettings(settings, into: &source)
    }

    // A rule without a scope carries the editor's own colors in a tmTheme. It stays in the rule list,
    // where the tokenColors filter drops it, as VS Code does.
    private func convertSettings(_ settings: [VSCodeThemeValue], into source: inout VSCodeThemeSource) {
        for rule in settings {
            source.tokenRules.append(rule)
            guard
                let entry = rule.objectValue,
                !(entry["scope"]?.isTruthy ?? false),
                let global = entry["settings"]?.objectValue
            else { continue }

            for (key, value) in global {
                guard let colorKey = Self.globalSettingColors[key], let raw = value.stringValue else { continue }
                source.colors[colorKey] = VSCodeColorSyntax.color(raw)
            }
        }
    }

    // Lexical first, so `../` is refused even when the target is missing; then again after symlinks,
    // so a link inside the folder cannot point out of it.
    private func containedFile(_ path: String, from directory: URL) throws -> URL {
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { throw ThemeLoadError.includeOutsideFolder(path) }

        let candidate = directory.appendingPathComponent(path).standardizedFileURL
        guard isInsideFolder(candidate) else { throw ThemeLoadError.includeOutsideFolder(path) }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ThemeLoadError.includeMissing(path)
        }

        let resolved = candidate.resolvingSymlinksInPath()
        guard isInsideFolder(resolved) else { throw ThemeLoadError.includeOutsideFolder(path) }
        return resolved
    }

    private func isInsideFolder(_ url: URL) -> Bool {
        let base = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        return url.path.hasPrefix(base)
    }
}
