import Foundation
import os
import TableProLogRedaction

// The mapping choices a user made for one table, kept as departures from the name match (macOS
// `ImportColumnMappingStore`), so a column the table gains later is still found by name.
nonisolated struct ImportMappingStore: @unchecked Sendable {
    nonisolated struct Key: Hashable, Sendable {
        let connectionId: UUID
        let database: String?
        let schema: String?
        let table: String

        var defaultsKey: String {
            let parts = [database ?? "", schema ?? "", table].map { $0.replacingOccurrences(of: "\u{1F}", with: "", options: .literal) }
            return "com.TablePro.importMapping.\(connectionId.uuidString).\(parts.joined(separator: "\u{1F}"))"
        }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "ImportMappingStore")

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func overrides(for key: Key) -> [String: ImportMappingOverride] {
        guard let data = defaults.data(forKey: key.defaultsKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: ImportMappingOverride].self, from: data)
        } catch {
            Self.logger.warning("A saved import mapping could not be read: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            return [:]
        }
    }

    // Entries for fields this file does not hold are kept, so several layouts into one table all come back.
    func remember(_ overrides: [String: ImportMappingOverride], fields: [String], for key: Key) {
        let merged = ImportColumnMatcher.merging(overrides, forFields: fields, into: self.overrides(for: key))
        guard !merged.isEmpty else {
            defaults.removeObject(forKey: key.defaultsKey)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(merged), forKey: key.defaultsKey)
        } catch {
            Self.logger.warning("An import mapping could not be saved: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    func forget(_ key: Key) {
        defaults.removeObject(forKey: key.defaultsKey)
    }
}
