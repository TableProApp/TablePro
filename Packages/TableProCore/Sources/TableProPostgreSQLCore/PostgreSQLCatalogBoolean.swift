import Foundation

nonisolated public enum PostgreSQLCatalogBoolean {
    private static let trueSpellings: Set<String> = ["t", "true", "yes", "on", "1"]

    public static func isTrue(_ text: String?) -> Bool {
        guard let text else { return false }
        return trueSpellings.contains(text.lowercased())
    }
}
