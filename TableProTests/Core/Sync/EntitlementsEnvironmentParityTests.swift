//
//  EntitlementsEnvironmentParityTests.swift
//  TableProTests
//
//  Guards the CloudKit environment pin. The Mac and iOS apps must both target
//  the Production environment, or a development iOS build talks to the
//  Development database while the Mac talks to Production and sync silently
//  moves nothing across devices.
//

import Foundation
import Testing

@Suite("CloudKit environment entitlement parity")
struct EntitlementsEnvironmentParityTests {
    private static let environmentKey = "com.apple.developer.icloud-container-environment"
    private static let macEntitlements = "TablePro/TablePro.entitlements"
    private static let iosEntitlements = "TableProMobile/TableProMobile/TableProMobileRelease.entitlements"

    @Test("Mac app pins the Production CloudKit environment")
    func macTargetsProduction() throws {
        try #expect(environment(in: Self.macEntitlements) == "Production")
    }

    @Test("iOS app pins the Production CloudKit environment")
    func iosTargetsProduction() throws {
        try #expect(environment(in: Self.iosEntitlements) == "Production")
    }

    private func environment(in relativePath: String) throws -> String? {
        let url = try repoRoot().appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let entitlements = try #require(plist as? [String: Any], "Entitlements at \(relativePath) is not a dictionary")
        return entitlements[Self.environmentKey] as? String
    }

    private func repoRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            let marker = directory.appendingPathComponent("TablePro.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw EntitlementsParityError.repoRootNotFound
    }

    private enum EntitlementsParityError: Error {
        case repoRootNotFound
    }
}
