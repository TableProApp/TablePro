//
//  LiteralColorGuardTests.swift
//  TableProTests
//
//  A hand-set RGB, white or hex color never follows Light and Dark, Accent, Highlight or Increase
//  Contrast. Colors are either a system semantic color or a value inside a theme definition.
//

import Foundation
import Testing

struct LiteralColorGuardTests {
    private static let scannedTrees = ["TablePro", "Packages/TableProEditor/Sources"]

    // Theme definitions are where fixed colors belong.
    private static let allowedDirectories = ["TablePro/Theme/"]

    // A plugin's brand color is metadata about the engine, drawn on its glyph.
    private static let brandColorFilePrefix = "PluginMetadataRegistry"
    private static let brandColorLineMarker = "brandColorHex"

    private static let allowedFiles = [
        // Maps a TablePlus status color from a connection URL onto the connection palette.
        "ConnectionURLParser.swift",
        // Swatches a CSS color found in the user's own JSON or PHP value.
        "RGBAColor+NSColor.swift",
        // Derives a gray from a color it is handed, inside the editor package.
        "NSColor+Greyscale.swift",
    ]

    static func isAllowed(path: String, line: String) -> Bool {
        if allowedDirectories.contains(where: { path.hasPrefix($0) }) {
            return true
        }
        let fileName = (path as NSString).lastPathComponent
        if allowedFiles.contains(fileName) || fileName.contains("Fixture") {
            return true
        }
        return fileName.hasPrefix(brandColorFilePrefix) && line.contains(brandColorLineMarker)
    }

    static func rules() throws -> [ThemeSourceScan.Rule] {
        [
            try ThemeSourceScan.Rule("RGB color", #"\b(?:NS)?Color\(red:"#),
            try ThemeSourceScan.Rule(
                "RGB color",
                #"\bNSColor\((?:srgbRed|calibratedRed|deviceRed|displayP3Red):"#
            ),
            try ThemeSourceScan.Rule("color space color", #"\bColor\(\s*\.(?:sRGB|sRGBLinear|displayP3)\s*,"#),
            try ThemeSourceScan.Rule("white color", #"\b(?:NS)?Color\(white:"#),
            try ThemeSourceScan.Rule("white color", #"\bNSColor\((?:calibratedWhite|deviceWhite):"#),
            try ThemeSourceScan.Rule("hex color", ##""#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?(?![0-9A-Fa-f])"##),
        ]
    }

    @Test("No literal color outside the theme definitions")
    func noLiteralColors() throws {
        let rules = try Self.rules()
        let tree = try ThemeSourceScan.scan(Self.scannedTrees, rules: rules)
        let lines = tree.lines.filter { !Self.isAllowed(path: $0.path, line: $0.text) }
        let offenders = ThemeSourceScan.violations(in: lines, rules: rules)

        #expect(tree.fileCount > 1_000, "Scanned only \(tree.fileCount) files; the tree did not resolve")
        #expect(
            offenders.isEmpty,
            """
            These hand-set a color. Use a system color (Color.primary, .secondary, NSColor.labelColor, \
            .systemRed, .separatorColor) or, for the editor and the grid, a theme slot:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("Every allowlisted file still exists")
    func allowlistIsCurrent() throws {
        var fileNames: Set<String> = []
        _ = try ThemeSourceScan.scan(Self.scannedTrees) { path in
            fileNames.insert((path as NSString).lastPathComponent)
            return false
        }

        for name in Self.allowedFiles {
            #expect(fileNames.contains(name), "\(name) is allowlisted but no longer exists")
        }
    }

    @Test("The guard flags each literal form and passes system colors")
    func matcherCatchesAViolation() throws {
        let sample = """
        Color(red: 1.0, green: 0.4, blue: 0.47)
        NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        context.fill(Path(rect), with: .color(Color(white: 0.88)))
        NSColor(calibratedWhite: 0.5, alpha: 1)
        let accent = "#FF79C6"
        let tint = Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6, opacity: 1)
        // Color(red: 0, green: 0, blue: 0) in a comment
        let label = NSColor.labelColor
        let issue = "#1234 was fixed"
        let tooLong = "#FF79C6A"
        """
        let lines = ThemeSourceScan.flaggedLines(in: sample, rules: try Self.rules())

        #expect(lines == [1, 2, 3, 4, 5, 6])
    }

    @Test("Brand colors are allowed only on their own line in the registry")
    func brandColorExemptionIsNarrow() {
        let registry = "TablePro/Core/Plugins/PluginMetadataRegistry+CuratedDefaults.swift"
        #expect(Self.isAllowed(path: registry, line: ##"brandColorHex: "#336791","##))
        #expect(!Self.isAllowed(path: registry, line: ##"let tint = "#336791""##))
        #expect(!Self.isAllowed(path: "TablePro/Views/AIChat/ChatComposerView.swift", line: "Color(red: 1, green: 0, blue: 0)"))
    }
}
