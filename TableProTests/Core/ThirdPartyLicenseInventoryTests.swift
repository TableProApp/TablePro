//
//  ThirdPartyLicenseInventoryTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// The drift gate behind the acknowledgements list.
///
/// Versions move every time a library is bumped, and a licence can change with them: OpenSSL
/// relicensed at 3.0, Redis at 7.4 and again at 8.0. So the shipped version is checked against
/// the pin in the build scripts, and a mismatch fails here rather than being auto-corrected,
/// because the right response to a bump is for a person to re-read the upstream licence.
@Suite("Third-party license inventory")
struct ThirdPartyLicenseInventoryTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    private static var inventoryRoot: URL {
        repositoryRoot
            .appendingPathComponent("TablePro/Resources")
            .appendingPathComponent(ThirdPartyLicenseInventory.resourceDirectoryName)
    }

    private func loadInventory() throws -> ThirdPartyLicenseInventory {
        try ThirdPartyLicenseInventory(rootURL: Self.inventoryRoot)
    }

    /// Every `NAME_VERSION="value"` literal the build scripts pin, which is what the shipped
    /// static libraries are actually built from.
    private static func shellVersionPins() throws -> [String: String] {
        let scripts = repositoryRoot.appendingPathComponent("scripts")
        let names = try FileManager.default.contentsOfDirectory(atPath: scripts.path)
            .filter { $0.hasPrefix("build-") && $0.hasSuffix(".sh") } + ["openssl-version.sh"]

        let pattern = try NSRegularExpression(pattern: #"^([A-Z0-9_]+_VERSION)="(v?[0-9][^"$]*)""#, options: [.anchorsMatchLines])
        var pins: [String: String] = [:]
        for name in names {
            let path = scripts.appendingPathComponent(name)
            guard let source = try? String(contentsOf: path, encoding: .utf8) else { continue }
            let range = NSRange(source.startIndex ..< source.endIndex, in: source)
            for match in pattern.matches(in: source, range: range) {
                guard let key = Range(match.range(at: 1), in: source),
                      let value = Range(match.range(at: 2), in: source) else { continue }
                pins[String(source[key])] = String(source[value])
            }
        }
        return pins
    }

    private static func swiftPackagePins() throws -> [String: Set<String>] {
        let files = [
            "TablePro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "Packages/TableProOracle/Package.resolved",
            "TableProMobile/TableProMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        ]

        var pins: [String: Set<String>] = [:]
        for file in files {
            let url = repositoryRoot.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = root["pins"] as? [[String: Any]] else { continue }
            for entry in entries {
                guard let identity = entry["identity"] as? String,
                      let state = entry["state"] as? [String: Any] else { continue }
                let version = (state["version"] as? String) ?? (state["revision"] as? String).map { "rev:\($0)" }
                guard let version else { continue }
                pins[identity, default: []].insert(version)
            }
        }
        return pins
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

    @Test("No two components share an id")
    func idsAreUnique() throws {
        let inventory = try loadInventory()
        let ids = inventory.components.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @Test("Every referenced license text exists and carries a body")
    func licenseTextsExist() throws {
        let inventory = try loadInventory()
        for file in inventory.distinctTextFiles() {
            let url = Self.inventoryRoot.appendingPathComponent(file)
            let text = try? String(contentsOf: url, encoding: .utf8)
            #expect(text != nil, "missing license text: \(file)")
            #expect((text?.count ?? 0) > 300, "license text looks truncated: \(file)")
        }
    }

    @Test("Every shipped license text is referenced by a component")
    func noOrphanedLicenseTexts() throws {
        let inventory = try loadInventory()
        let referenced = Set(inventory.distinctTextFiles())
        let textsDirectory = Self.inventoryRoot.appendingPathComponent(ThirdPartyLicenseInventory.textsDirectoryName)
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: textsDirectory.path)) ?? []
        let orphans = onDisk
            .filter { $0.hasSuffix(".txt") }
            .map { "\(ThirdPartyLicenseInventory.textsDirectoryName)/\($0)" }
            .filter { !referenced.contains($0) }

        #expect(orphans.isEmpty, "license texts nothing references: \(orphans.sorted().joined(separator: ", "))")
    }

    @Test("A component's recorded version matches the version its build script pins")
    func shellPinsMatch() throws {
        let inventory = try loadInventory()
        let pins = try Self.shellVersionPins()

        for component in inventory.components {
            guard case .shellVariable(let variable) = component.versionSource else { continue }
            let pinned = pins[variable]
            #expect(pinned != nil, "\(component.id) points at \(variable), which no build script defines")
            guard let pinned else { continue }
            #expect(
                pinned.normalizedVersion == component.version.normalizedVersion,
                """
                \(component.id) is recorded as \(component.version) but \(variable) pins \(pinned).
                Re-read the upstream license at the new version before updating this entry:
                a bump can change the license, as OpenSSL did at 3.0 and Redis at 7.4.
                """
            )
        }
    }

    @Test("A component's recorded version matches the version SwiftPM resolved")
    func swiftPackagePinsMatch() throws {
        let inventory = try loadInventory()
        let pins = try Self.swiftPackagePins()

        for component in inventory.components {
            guard case .swiftPackage(let identity) = component.versionSource else { continue }
            let resolved = pins[identity]
            #expect(resolved != nil, "\(component.id) points at SwiftPM package \(identity), which nothing resolves")
            guard let resolved else { continue }

            /// A package can resolve to more than one version across the app, the Oracle
            /// package and the iOS app, and every one of them ships, so the entry has to
            /// name all of them rather than whichever was read first.
            let recorded = Set(component.version.components(separatedBy: ", "))
            #expect(
                recorded == resolved,
                """
                \(component.id) is recorded as \(recorded.sorted().joined(separator: ", ")) \
                but SwiftPM resolves \(resolved.sorted().joined(separator: ", ")).
                """
            )
        }
    }

    @Test("Every build-script pin is attributed by a component")
    func everyShellPinIsAttributed() throws {
        let inventory = try loadInventory()
        let attributedVariables = Set(inventory.components.compactMap { component -> String? in
            guard case .shellVariable(let variable) = component.versionSource else { return nil }
            return variable
        })

        let unattributed = try Self.shellVersionPins().keys.filter { !attributedVariables.contains($0) }

        #expect(
            unattributed.isEmpty,
            """
            These libraries are built and shipped with no license entry: \
            \(unattributed.sorted().joined(separator: ", ")).
            Add each to TablePro/Resources/ThirdPartyLicenses/licenses.yml.
            """
        )
    }

    @Test("The patched flag agrees with the patches on disk")
    func patchedFlagMatchesPatchDirectories() throws {
        let inventory = try loadInventory()
        let patchesRoot = Self.repositoryRoot.appendingPathComponent("scripts/patches")
        let patchedOnDisk = Set((try? FileManager.default.contentsOfDirectory(atPath: patchesRoot.path)) ?? [])
        let patchedInInventory = Set(inventory.components.filter(\.patched).map(\.id))

        for id in patchedOnDisk where !id.hasPrefix(".") {
            #expect(
                patchedInInventory.contains(id),
                "scripts/patches/\(id) exists but \(id) is not marked patched in the license inventory"
            )
        }
        for id in patchedInInventory {
            #expect(
                patchedOnDisk.contains(id),
                "\(id) is marked patched but scripts/patches/\(id) does not exist"
            )
        }
    }
}

private extension String {
    /// Build scripts pin some tags with a leading `v`; the upstream release is the same one.
    var normalizedVersion: String {
        hasPrefix("v") ? String(dropFirst()) : self
    }
}
