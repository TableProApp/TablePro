import Foundation
@testable import TablePro
import Testing

struct RegistryReleaseSelectionTests {
    private static let ventura = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)

    private func release(
        build: Int,
        kit: Int,
        channel: String = "stable",
        minimumSystemVersion: String = "13.0"
    ) -> RegistryRelease {
        RegistryRelease(
            version: "0.0.\(build)",
            build: build,
            channel: channel,
            pluginKit: kit,
            minimumSystemVersion: minimumSystemVersion,
            url: "https://example.com/\(build).zip",
            sha256: String(repeating: "a", count: 64)
        )
    }

    private func plugin(_ releases: [RegistryRelease]) -> RegistryPlugin {
        RegistryPlugin(
            id: "com.example.driver",
            name: "Example Driver",
            databaseTypeIds: ["Example"],
            exportFormatIds: [],
            releases: releases
        )
    }

    private func newest(
        _ releases: [RegistryRelease],
        channel: UpdateChannel = .stable,
        kits: ClosedRange<Int> = 39...40,
        systemVersion: OperatingSystemVersion = ventura
    ) throws -> RegistryRelease {
        try plugin(releases).newestRelease(channel: channel, kits: kits, systemVersion: systemVersion)
    }

    @Test("The highest build in the kit range wins")
    func highestBuildInRange() throws {
        let picked = try newest([release(build: 820_099, kit: 39), release(build: 820_199, kit: 40)])

        #expect(picked.build == 820_199)
    }

    @Test("A release with a kit above or below the range is skipped")
    func kitOutsideRangeSkipped() throws {
        let picked = try newest([
            release(build: 830_099, kit: 41),
            release(build: 820_099, kit: 39),
            release(build: 810_099, kit: 38)
        ])

        #expect(picked.build == 820_099)
    }

    @Test("A stable app skips a beta release and a beta app takes it")
    func betaFollowsTheAppChannel() throws {
        let releases = [release(build: 820_099, kit: 39), release(build: 830_001, kit: 39, channel: "beta")]

        #expect(try newest(releases, channel: .stable).build == 820_099)
        #expect(try newest(releases, channel: .beta).build == 830_001)
    }

    @Test("A release in a channel the app does not know is skipped, and the manifest still decodes")
    func unknownChannelSkipped() throws {
        let json = """
        {"schemaVersion": 3, "retainFromPluginKit": 39, "plugins": [{
            "id": "com.example.driver", "name": "Example Driver", "databaseTypeIds": ["Example"], "exportFormatIds": [],
            "releases": [
                {"version": "0.83.0-nightly.1", "build": 830050, "channel": "nightly", "pluginKit": 39,
                 "minimumSystemVersion": "13.0", "url": "https://example.com/n.zip", "sha256": "\(String(repeating: "b", count: 64))"},
                {"version": "0.82.0", "build": 820099, "channel": "stable", "pluginKit": 39,
                 "minimumSystemVersion": "13.0", "url": "https://example.com/s.zip", "sha256": "\(String(repeating: "c", count: 64))"}
            ]
        }]}
        """
        let manifest = try JSONDecoder().decode(RegistryManifest.self, from: Data(json.utf8))
        let entry = try #require(manifest.plugins.first)
        let picked = try entry.newestRelease(channel: .beta, kits: 39...39, systemVersion: Self.ventura)

        #expect(entry.releases.count == 2)
        #expect(picked.build == 820_099)
    }

    @Test("A release that needs a newer macOS than the running one is skipped")
    func newerSystemSkipped() throws {
        let picked = try newest([
            release(build: 820_199, kit: 39, minimumSystemVersion: "14.0"),
            release(build: 820_099, kit: 39, minimumSystemVersion: "13.0")
        ])

        #expect(picked.build == 820_099)
    }

    @Test("A three-part minimumSystemVersion compares part by part")
    func patchLevelSystemVersion() throws {
        let candidates = [release(build: 820_199, kit: 39, minimumSystemVersion: "13.4.1")]
        let ventura5 = OperatingSystemVersion(majorVersion: 13, minorVersion: 5, patchVersion: 0)

        #expect(try newest(candidates, systemVersion: ventura5).build == 820_199)
        #expect(throws: PluginError.self) { try newest(candidates, systemVersion: Self.ventura) }
    }

    @Test("Only releases above the app's kit report that the app is too old")
    func appTooOldForPlugin() {
        #expect {
            _ = try newest([release(build: 840_099, kit: 42), release(build: 830_099, kit: 41)])
        } throws: { error in
            guard case PluginError.appTooOldForPlugin(let oldest, let appKit) = error else { return false }
            return oldest == 41 && appKit == 40
        }
    }

    @Test("Nothing selectable and nothing newer reports no compatible release")
    func noCompatibleRelease() {
        let candidates = [
            release(build: 810_099, kit: 38),
            release(build: 830_001, kit: 41, channel: "beta"),
            release(build: 830_099, kit: 41, minimumSystemVersion: "15.0")
        ]

        #expect {
            _ = try newest(candidates, channel: .stable)
        } throws: { error in
            guard case PluginError.noCompatibleRelease = error else { return false }
            return true
        }
    }

    @Test("A v2 document is refused")
    func schemaTwoRefused() {
        let json = #"{"schemaVersion": 2, "plugins": []}"#

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RegistryManifest.self, from: Data(json.utf8))
        }
    }
}
