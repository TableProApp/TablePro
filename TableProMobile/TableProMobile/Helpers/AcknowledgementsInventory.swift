import Foundation
import os

nonisolated struct AcknowledgementComponent: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String
    let spdx: String
    let copyrights: [String]
    let homepageURL: String
    let textFile: String?

    private static let revisionPrefix = "rev:"
    private static let shortRevisionLength = 7

    var displayVersion: String {
        guard version.hasPrefix(Self.revisionPrefix) else { return version }
        return String(version.dropFirst(Self.revisionPrefix.count).prefix(Self.shortRevisionLength))
    }

    var homepage: URL? {
        URL(string: homepageURL)
    }
}

nonisolated enum AcknowledgementsInventoryError: Error, Equatable {
    case manifestMissing
    case licenseTextMissing(componentId: String)
}

nonisolated struct AcknowledgementsInventory: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "Acknowledgements")

    static let manifestName = "Acknowledgements"
    static let manifestExtension = "json"

    let components: [AcknowledgementComponent]
    private let rootURL: URL

    init(manifestURL: URL) throws {
        let data = try Data(contentsOf: manifestURL)
        components = try JSONDecoder().decode([AcknowledgementComponent].self, from: data)
        rootURL = manifestURL.deletingLastPathComponent()
    }

    static func bundled(in bundle: Bundle = .main) throws -> AcknowledgementsInventory {
        guard let manifestURL = bundle.url(forResource: manifestName, withExtension: manifestExtension) else {
            logger.error("Acknowledgements manifest is missing from the app bundle")
            throw AcknowledgementsInventoryError.manifestMissing
        }
        do {
            return try AcknowledgementsInventory(manifestURL: manifestURL)
        } catch {
            logger.error("Could not read the acknowledgements manifest: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    func licenseText(for component: AcknowledgementComponent) throws -> String {
        guard let textFile = component.textFile else {
            throw AcknowledgementsInventoryError.licenseTextMissing(componentId: component.id)
        }
        do {
            return try String(contentsOf: rootURL.appendingPathComponent(textFile), encoding: .utf8)
        } catch {
            Self.logger.error(
                "Missing license text \(textFile, privacy: .public) for \(component.id, privacy: .public)"
            )
            throw AcknowledgementsInventoryError.licenseTextMissing(componentId: component.id)
        }
    }
}
