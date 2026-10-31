import Foundation
@testable import TablePro
import Testing

struct WhatsNewContentTests {
    @Test("Takes the title from the leading heading and keeps the rest as body")
    func parsesTitleAndBody() {
        let content = WhatsNewContent.parse("""
        # TablePro 0.75.0

        Map view for results holding a geometry column.
        Row-number gutter held at the left edge.
        """)

        #expect(content.title == "TablePro 0.75.0")
        #expect(content.paragraphs.count == 2)
        #expect(String(content.paragraphs[0].characters).contains("Map view"))
        #expect(String(content.paragraphs[1].characters).contains("Row-number gutter"))
    }

    /// Each line is its own point, so a whole-document parse that merged them into one block
    /// would be wrong.
    @Test("Keeps each line as its own paragraph")
    func keepsLinesSeparate() {
        let content = WhatsNewContent.parse("# T\n\nOne.\nTwo.\nThree.\n")

        #expect(content.paragraphs.count == 3)
    }

    @Test("Renders inline markdown rather than showing its syntax")
    func rendersInlineMarkdown() {
        let content = WhatsNewContent.parse("# T\n\n**Map view** for `geometry` columns.\n")
        let rendered = String(content.paragraphs[0].characters)

        #expect(!rendered.contains("**"))
        #expect(!rendered.contains("`"))
        #expect(rendered.contains("Map view"))
        #expect(rendered.contains("geometry"))
    }

    @Test("Falls back to a pointer when the file holds nothing")
    func fallsBackWhenEmpty() {
        let content = WhatsNewContent.parse("")

        #expect(!content.title.isEmpty)
        #expect(content.paragraphs.count == 1)
    }

    @Test("A file with only a heading still offers something to read")
    func headingOnly() {
        let content = WhatsNewContent.parse("# TablePro 0.75.0\n")

        #expect(content.title == "TablePro 0.75.0")
        #expect(content.paragraphs.count == 1)
    }

    @Test("A bundle with notes loads them")
    func bundleWithNotesLoads() throws {
        try withBundle(version: "0.82.0", notes: "# TablePro 0.82.0\n\nBeta updates.\n") { bundle in
            let content = try #require(WhatsNewContent.load(from: bundle))

            #expect(content.title == "TablePro 0.82.0")
            #expect(content.paragraphs.map { String($0.characters) } == ["Beta updates."])
        }
    }

    @Test("A bundle without notes loads nothing")
    func bundleWithoutNotesLoadsNothing() throws {
        try withBundle(version: "0.0.0-dev", notes: nil) { bundle in
            #expect(WhatsNewContent.load(from: bundle) == nil)
        }
    }

    @Test("Without notes the Welcome link stays hidden and the seen version is not written")
    func noNotesNoLinkNoWrite() throws {
        let suite = try EphemeralDefaults()
        suite.defaults.set("0.81.0", forKey: PreferenceKeys.lastSeenAppVersion.name)

        try withBundle(version: "0.0.0-dev", notes: nil) { bundle in
            let showsLink = WhatsNewNotice(bundle: bundle, defaults: suite.defaults).recordLaunch()

            #expect(!showsLink)
            #expect(suite.defaults.string(forKey: PreferenceKeys.lastSeenAppVersion.name) == "0.81.0")
        }
    }

    @Test("With notes a newer build shows the Welcome link and is recorded as seen")
    func notesShowLinkForNewerBuild() throws {
        let suite = try EphemeralDefaults()
        suite.defaults.set(810_099, forKey: PreferenceKeys.lastSeenAppBuild.name)

        try withBundle(version: "0.82.0", build: 820_099, notes: "# TablePro 0.82.0\n") { bundle in
            let showsLink = WhatsNewNotice(bundle: bundle, defaults: suite.defaults).recordLaunch()

            #expect(showsLink)
            #expect(suite.defaults.integer(forKey: PreferenceKeys.lastSeenAppBuild.name) == 820_099)
        }
    }

    @Test("A first launch records the build without the Welcome link")
    func firstLaunchHasNoLink() throws {
        let suite = try EphemeralDefaults()

        try withBundle(version: "0.82.0", build: 820_099, notes: "# TablePro 0.82.0\n") { bundle in
            let showsLink = WhatsNewNotice(bundle: bundle, defaults: suite.defaults).recordLaunch()

            #expect(!showsLink)
            #expect(suite.defaults.integer(forKey: PreferenceKeys.lastSeenAppBuild.name) == 820_099)
        }
    }

    @Test("An older build shows no link and leaves the newer build recorded")
    func olderBuildIsQuiet() throws {
        let suite = try EphemeralDefaults()
        suite.defaults.set(830_099, forKey: PreferenceKeys.lastSeenAppBuild.name)
        suite.defaults.set("0.83.0", forKey: PreferenceKeys.lastSeenAppVersion.name)

        try withBundle(version: "0.82.0", build: 820_099, notes: "# TablePro 0.82.0\n") { bundle in
            let showsLink = WhatsNewNotice(bundle: bundle, defaults: suite.defaults).recordLaunch()

            #expect(!showsLink)
            #expect(suite.defaults.integer(forKey: PreferenceKeys.lastSeenAppBuild.name) == 830_099)
            #expect(suite.defaults.string(forKey: PreferenceKeys.lastSeenAppVersion.name) == "0.83.0")
        }
    }

    @Test("The stable after its beta shows the link, and a relaunch does not")
    func stableAfterBetaShowsLinkOnce() throws {
        let suite = try EphemeralDefaults()
        suite.defaults.set(830_002, forKey: PreferenceKeys.lastSeenAppBuild.name)

        try withBundle(version: "0.83.0", build: 830_099, notes: "# TablePro 0.83.0\n") { bundle in
            let notice = WhatsNewNotice(bundle: bundle, defaults: suite.defaults)

            #expect(notice.recordLaunch())
            #expect(!notice.recordLaunch())
        }
    }

    @Test("The first build to record a build number shows the link after an older version")
    func legacyVersionRecordCarriesOver() throws {
        let suite = try EphemeralDefaults()
        suite.defaults.set("0.81.0", forKey: PreferenceKeys.lastSeenAppVersion.name)

        try withBundle(version: "0.82.0", build: 820_099, notes: "# TablePro 0.82.0\n") { bundle in
            let showsLink = WhatsNewNotice(bundle: bundle, defaults: suite.defaults).recordLaunch()

            #expect(showsLink)
            #expect(suite.defaults.integer(forKey: PreferenceKeys.lastSeenAppBuild.name) == 820_099)
        }
    }

    private func withBundle(
        version: String,
        build: Int = 1,
        notes: String?,
        _ body: (Bundle) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhatsNewContentTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Probe.bundle", isDirectory: true)
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = [
            "CFBundleIdentifier": "com.TablePro.WhatsNewProbe",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": String(build),
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        if let notes {
            try Data(notes.utf8).write(to: resources.appendingPathComponent("WhatsNew.md"))
        }
        let bundle = try #require(Bundle(url: bundleURL))
        try body(bundle)
    }
}
