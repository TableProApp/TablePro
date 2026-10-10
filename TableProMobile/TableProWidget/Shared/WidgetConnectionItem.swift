import Foundation

nonisolated struct WidgetConnectionItem: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let type: String
    let sortOrder: Int
    /// Resolved by the app, which links the engine catalog the widget does not. Nil in a file an
    /// older build wrote.
    let glyph: ConnectionGlyph?
}

nonisolated struct ConnectionGlyph: Codable, Hashable, Sendable {
    nonisolated enum Source: String, Codable, Sendable {
        case asset
        case symbol
    }

    static let fallback = ConnectionGlyph(source: .symbol, name: "cylinder.split.1x2")

    let source: Source
    let name: String
}
