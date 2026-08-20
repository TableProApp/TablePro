//
//  ThirdPartyLicenseInventory.swift
//  TablePro
//

import Foundation
import os
import Yams

/// Reads the open source components TablePro redistributes, and the licence bodies it is
/// obliged to reproduce.
///
/// The obligation is real and not decorative: MariaDB Connector/C is LGPL 2.1 and FreeTDS is
/// LGPL 2.0, both statically linked into shipped plugin bundles, and section 6 of each requires
/// the distributed work to say the library is used, that its use is covered by that licence, and
/// to include a copy of it. MIT, BSD, ISC and the PostgreSQL licence all require their body to
/// travel with the binary too, so this ships the texts rather than a credits list.
struct ThirdPartyLicenseInventory {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ThirdPartyLicenses")

    static let resourceDirectoryName = "ThirdPartyLicenses"
    static let inventoryFileName = "licenses.yml"
    static let textsDirectoryName = "texts"

    let components: [ThirdPartyComponent]
    private let rootURL: URL

    /// Components with a confirmed licence, which is what the acknowledgements list renders.
    var attributed: [ThirdPartyComponent] {
        components.filter { !$0.isUnverified }
    }

    /// Components whose licence could not be confirmed from a primary source. Surfaced rather
    /// than dropped, so an unresolved obligation stays visible instead of looking discharged.
    var unresolved: [ThirdPartyComponent] {
        components.filter(\.isUnverified)
    }

    init(rootURL: URL) throws {
        self.rootURL = rootURL
        let yaml = try String(contentsOf: rootURL.appendingPathComponent(Self.inventoryFileName), encoding: .utf8)
        let decoded = try YAMLDecoder().decode([ThirdPartyComponent].self, from: yaml)
        components = decoded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func bundled(in bundle: Bundle = .main) -> ThirdPartyLicenseInventory? {
        guard let root = bundle.url(forResource: resourceDirectoryName, withExtension: nil) else {
            logger.error("Third-party licence inventory is missing from the app bundle")
            return nil
        }
        do {
            return try ThirdPartyLicenseInventory(rootURL: root)
        } catch {
            logger.error("Could not read the third-party licence inventory: \(error.localizedDescription)")
            return nil
        }
    }

    func licenseText(for component: ThirdPartyComponent) -> String? {
        guard let textFile = component.textFile else { return nil }
        let url = rootURL.appendingPathComponent(textFile)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            Self.logger.error("Missing license text \(textFile, privacy: .public) for \(component.id, privacy: .public)")
            return nil
        }
        return text
    }

    /// Every distinct licence body the inventory references, so the page can render each once
    /// instead of repeating a licence per component that uses it.
    func distinctTextFiles() -> [String] {
        Set(components.compactMap(\.textFile)).sorted()
    }
}
