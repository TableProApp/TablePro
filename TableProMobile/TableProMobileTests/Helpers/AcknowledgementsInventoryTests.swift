import Foundation
import Testing

@testable import TableProMobile

@Suite("Acknowledgements inventory")
struct AcknowledgementsInventoryTests {
    @Test("the bundled acknowledgements decode and name the libraries the app links")
    func bundledInventoryDecodes() throws {
        let inventory = try AcknowledgementsInventory.bundled()
        let ids = Set(inventory.components.map(\.id))

        #expect(!inventory.components.isEmpty)
        for required in ["openssl", "libssh2", "chinook"] {
            #expect(ids.contains(required), "\(required) is missing from the bundled acknowledgements")
        }
    }

    @Test("every license text the acknowledgements name is in the app bundle")
    func everyLicenseTextResolves() throws {
        let inventory = try AcknowledgementsInventory.bundled()

        for component in inventory.components where component.textFile != nil {
            let text = try? inventory.licenseText(for: component)
            #expect(text?.isEmpty == false, "\(component.id) names a license text the app bundle does not carry")
        }
    }

    @Test("a license text missing from disk is reported rather than read as empty")
    func missingLicenseTextThrows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcknowledgementsInventoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = """
            [{"id": "absent", "name": "Absent", "version": "1.0", "spdx": "MIT", "copyrights": [],
              "homepageURL": "https://example.com", "textFile": "texts/absent.txt"}]
            """
        let manifestURL = root.appendingPathComponent("Acknowledgements.json")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        let inventory = try AcknowledgementsInventory(manifestURL: manifestURL)
        let component = try #require(inventory.components.first)

        #expect(throws: AcknowledgementsInventoryError.licenseTextMissing(componentId: "absent")) {
            try inventory.licenseText(for: component)
        }
    }

    @Test("a pinned revision shows as a short hash, a release version as written")
    func displayVersion() throws {
        let data = Data("""
            [{"id": "pinned", "name": "Pinned", "version": "rev:f09d088889e252655ea1833eed821cd2be0de03a",
              "spdx": "MIT", "copyrights": [], "homepageURL": "https://example.com", "textFile": null},
             {"id": "release", "name": "Release", "version": "3.4.4", "spdx": "MIT", "copyrights": [],
              "homepageURL": "https://example.com", "textFile": null}]
            """.utf8)
        let components = try JSONDecoder().decode([AcknowledgementComponent].self, from: data)

        #expect(components.map(\.displayVersion) == ["f09d088", "3.4.4"])
    }
}
