//
//  ThirdPartyComponent.swift
//  TablePro
//

import Foundation

/// One open source library TablePro links and redistributes.
///
/// Distinct from the `License*` types, which model the commercial licence a user buys.
struct ThirdPartyComponent: Codable, Identifiable, Hashable {
    /// Where the shipped version is pinned, so a bump cannot pass unnoticed.
    ///
    /// `shellVariable` and `swiftPackage` are checked against the real pin by
    /// `ThirdPartyLicenseInventoryTests`. `manual` opts out, and is only correct for a
    /// component whose version is recorded nowhere a machine can read.
    enum VersionSource: Hashable {
        case shellVariable(String)
        case swiftPackage(String)
        case manual

        init(rawValue: String) {
            if let name = rawValue.dropPrefixIfPresent("sh:") {
                self = .shellVariable(name)
            } else if let identity = rawValue.dropPrefixIfPresent("spm:") {
                self = .swiftPackage(identity)
            } else {
                self = .manual
            }
        }

        var rawValue: String {
            switch self {
            case .shellVariable(let name): "sh:\(name)"
            case .swiftPackage(let identity): "spm:\(identity)"
            case .manual: "manual"
            }
        }
    }

    enum Platform: String, Codable, Hashable {
        case macos
        case ios
    }

    let id: String
    let name: String
    let version: String
    let spdx: String
    let copyrights: [String]
    let homepageURL: String
    let licenseTextURL: String
    /// Path of the licence body under the inventory's `texts/` directory. Absent only for
    /// a component whose licence is still unverified, which never renders as attributed.
    let textFile: String?
    let source: String
    let patched: Bool
    let notes: String?
    let platforms: [Platform]

    var versionSource: VersionSource { VersionSource(rawValue: source) }

    func ships(on platform: Platform) -> Bool {
        platforms.contains(platform)
    }

    /// A component whose licence has not been confirmed from a primary source. It is listed
    /// as unresolved rather than being given a guessed licence, because a wrong SPDX line is
    /// a licence violation stated in the app's own voice.
    var isUnverified: Bool { spdx == ThirdPartyComponent.unverifiedSPDX }

    static let unverifiedSPDX = "UNVERIFIED"

    static let defaultPlatforms: [Platform] = [.macos]
}

extension ThirdPartyComponent {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        spdx = try container.decode(String.self, forKey: .spdx)
        copyrights = try container.decode([String].self, forKey: .copyrights)
        homepageURL = try container.decode(String.self, forKey: .homepageURL)
        licenseTextURL = try container.decode(String.self, forKey: .licenseTextURL)
        textFile = try container.decodeIfPresent(String.self, forKey: .textFile)
        source = try container.decode(String.self, forKey: .source)
        patched = try container.decode(Bool.self, forKey: .patched)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        platforms = try container.decodeIfPresent([Platform].self, forKey: .platforms) ?? Self.defaultPlatforms
    }
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
