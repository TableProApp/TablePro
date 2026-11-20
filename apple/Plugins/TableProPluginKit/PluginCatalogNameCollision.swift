import Foundation

// A schema-wide read keyed by String would merge two objects whose names differ only in Unicode form (NFC and NFD),
// which a server can keep apart, so the read throws this and the host reads each object alone.
public struct PluginCatalogNameCollision: Error, LocalizedError, Sendable, Equatable {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    public var errorDescription: String? {
        String(format: String(localized: "Two objects share the name “%@” in different Unicode forms."), name)
    }

    static func requireDistinctSpellings(_ names: some Sequence<String>) throws {
        var seen = Set<String>()
        for name in names {
            let (inserted, known) = seen.insert(name)
            if !inserted, !known.utf8.elementsEqual(name.utf8) {
                throw PluginCatalogNameCollision(name: name)
            }
        }
    }
}
