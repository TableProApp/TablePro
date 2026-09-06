import Foundation

nonisolated enum RedisDatabaseIndex {
    static let fieldName = "redisDatabase"

    /// The driver names databases `db0` upward everywhere it shows one, and `switchDatabase`
    /// reads that spelling back, so connecting has to accept it too. Taking only a bare integer
    /// made a saved `db4` resolve to 0 and browse the wrong database with nothing said.
    static func resolve(additionalFields: [String: String], database: String) -> Int {
        if let field = additionalFields[fieldName], let index = parse(field) { return index }
        return parse(database) ?? 0
    }

    static func parse(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let index = Int(trimmed) { return index }
        guard trimmed.lowercased().hasPrefix("db") else { return nil }
        return Int(trimmed.dropFirst(2))
    }
}
