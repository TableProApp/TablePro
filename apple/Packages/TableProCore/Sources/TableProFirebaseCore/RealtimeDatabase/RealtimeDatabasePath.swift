import Foundation

public enum RealtimeDatabasePath {
    /// Characters the Realtime Database refuses in a key; checked before a write so the error
    /// names the key instead of coming back as a bare 400.
    static let forbidden = CharacterSet(charactersIn: ".#$[]/").union(.controlCharacters)

    public static func normalized(_ path: String) -> String {
        FirebaseScalars.split(path, separator: "/").joined(separator: "/")
    }

    /// An empty key stands for the node itself, which is how a node holding a plain value shows.
    public static func join(_ parent: String, _ key: String) -> String {
        let base = normalized(parent)
        guard !key.isEmpty else { return base }
        return base.isEmpty ? key : base + "/" + key
    }

    /// The `$key` of the row a node holding a plain value shows as. A key cannot hold `/`, so this
    /// can never name a child.
    public static func nodeKey(_ path: String) -> String {
        "/" + normalized(path)
    }

    public static func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.rangeOfCharacter(from: forbidden) == nil, key.utf8.count <= 768 else {
            throw FirebaseError.configuration(String(
                format: String(localized: "\"%@\" is not a valid key. Keys cannot be empty or contain . # $ [ ] or /."),
                key
            ))
        }
    }
}
