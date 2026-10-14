//
//  ThirdPartyLicenseInventoryTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct ThirdPartyLicenseInventoryTests {
    private func loadInventory() throws -> ThirdPartyLicenseInventory {
        let root = try #require(
            Bundle.main.url(forResource: ThirdPartyLicenseInventory.resourceDirectoryName, withExtension: nil)
        )
        return try ThirdPartyLicenseInventory(rootURL: root)
    }

    @Test("The inventory parses and is not empty")
    func inventoryParses() throws {
        let inventory = try loadInventory()
        #expect(!inventory.components.isEmpty)
    }

    @Test("Every component has the fields the notice obligation needs")
    func componentsAreComplete() throws {
        let inventory = try loadInventory()
        for component in inventory.components {
            #expect(!component.id.isEmpty, "an entry has no id")
            #expect(!component.name.isEmpty, "\(component.id) has no name")
            #expect(!component.version.isEmpty, "\(component.id) has no version")
            #expect(!component.homepageURL.isEmpty, "\(component.id) has no homepage")
            guard !component.isUnverified else { continue }
            #expect(!component.spdx.isEmpty, "\(component.id) has no SPDX id")
            #expect(component.textFile != nil, "\(component.id) names no license text")
        }
    }

    @Test("A component with no platforms ships on macOS only")
    func platformsDefaultToMacOS() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdPartyLicenseInventoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let yaml = """
            - id: mac-only
              name: Mac Only
              version: 1.0.0
              spdx: MIT
              copyrights: []
              homepageURL: https://example.com/mac
              licenseTextURL: https://example.com/mac/LICENSE
              textFile: texts/mac.txt
              source: manual
              patched: false
            - id: ios-only
              name: iOS Only
              version: 1.0.0
              spdx: MIT
              copyrights: []
              homepageURL: https://example.com/ios
              licenseTextURL: https://example.com/ios/LICENSE
              textFile: texts/ios.txt
              source: manual
              patched: false
              platforms: [ios]
            """
        try yaml.write(
            to: root.appendingPathComponent(ThirdPartyLicenseInventory.inventoryFileName),
            atomically: true,
            encoding: .utf8
        )

        let inventory = try ThirdPartyLicenseInventory(rootURL: root)
        let macOnly = try #require(inventory.components.first { $0.id == "mac-only" })

        #expect(macOnly.platforms == [.macos])
        #expect(inventory.attributed.map(\.id) == ["mac-only"])
    }
}
