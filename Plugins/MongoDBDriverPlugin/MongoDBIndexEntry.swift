import Foundation
import TableProPluginKit

/// One document `listIndexes` returned, read from the canonical Extended JSON text the server sent.
///
/// The key document's field order is the index: `{lastName: 1, firstName: -1}` and
/// `{firstName: -1, lastName: 1}` are two different indexes. A Swift dictionary cannot hold that
/// order, so the Structure tab listed compound keys in a different order on every fetch and Show
/// DDL wrote them alphabetically, with the TTL, partial filter and collation left out. Each value
/// stays canonical until the statement is written, so a partial filter's Int64 and whole Double
/// keep their types.
struct MongoDBIndexEntry {
    static let primaryIndexName = "_id_"

    /// Members that describe the catalog entry rather than the index, so `createIndex` is not sent them.
    private static let catalogMembers: Set<String> = ["v", "key", "ns"]

    let name: String
    let keyJson: String
    let keyFields: [(name: String, value: String)]
    let options: [(key: String, value: String)]
    let kind: MongoDBIndexKind

    init?(json: String) {
        let members = MongoScriptJson.members(of: json)
        guard let nameJson = members.first(where: { $0.key == "name" })?.value,
              let name = MongoScriptJson.decodedString(nameJson),
              let keyJson = members.first(where: { $0.key == "key" })?.value else {
            return nil
        }
        self.name = name
        self.keyJson = keyJson
        keyFields = MongoScriptJson.members(of: keyJson).map { (name: $0.key, value: $0.value) }
        options = members
            .filter { !Self.catalogMembers.contains($0.key) }
            .map { member in
                (key: member.key, value: member.key == "collation" ? MongoDBCollation.portable(member.value) : member.value)
            }
        kind = MongoDBIndexKind(keyFields: keyFields)
    }

    var isPrimary: Bool { name == Self.primaryIndexName }

    var isUnique: Bool { isPrimary || option("unique") == "true" }

    /// The fields in key order. A text index keys on `_fts` and `_ftsx` and names its fields only
    /// in `weights`, so those stand where `_fts` does.
    var columns: [String] {
        guard kind == .text, let weights = option("weights") else { return keyFields.map(\.name) }
        let weighted = MongoScriptJson.members(of: weights).map(\.key)
        return keyFields.flatMap { field -> [String] in
            switch field.name {
            case "_fts": return weighted
            case "_ftsx": return []
            default: return [field.name]
            }
        }
    }

    var pluginIndexInfo: PluginIndexInfo {
        PluginIndexInfo(
            name: name, columns: columns, isUnique: isUnique, isPrimary: isPrimary, type: kind.pluginTypeName
        )
    }

    func createIndexStatement(collection: String) -> String {
        let accessor = MongoDBShellText.collection(collection)
        let literals = MongoDBJsonLayout.shellObject(
            options.map { (key: $0.key, value: MongoDBShellLiteral.render($0.value)) }
        )
        return "\(accessor).createIndex(\(MongoDBShellLiteral.render(keyJson)), \(literals))"
    }

    private func option(_ key: String) -> String? {
        options.first { $0.key == key }?.value
    }
}

/// What an index's key makes it, in the index type names the app's structure editor uses.
enum MongoDBIndexKind: Equatable {
    case btree
    case hashed
    case text
    case sphere
    case wildcard
    case other(String)

    init(keyFields: [(name: String, value: String)]) {
        if let method = keyFields.lazy.compactMap({ MongoScriptJson.decodedString($0.value) }).first {
            switch method {
            case "text": self = .text
            case "hashed": self = .hashed
            case "2dsphere": self = .sphere
            default: self = .other(method)
            }
            return
        }
        let isWildcard = keyFields.contains { $0.name == "$**" || $0.name.hasSuffix(".$**") }
        self = isWildcard ? .wildcard : .btree
    }

    var pluginTypeName: String {
        switch self {
        case .btree: return "BTREE"
        case .hashed: return "HASH"
        case .text: return "FULLTEXT"
        case .sphere: return "SPATIAL"
        case .wildcard: return "WILDCARD"
        case .other(let method): return method.uppercased()
        }
    }
}

/// A collation as another server can take it.
///
/// The server reports the ICU `version` it built the collation with, and a server with a different
/// ICU build refuses a statement naming that version with code 161. Left out, the server that runs
/// the statement fills in its own, which on the same server is the same one.
enum MongoDBCollation {
    static func portable(_ collationJson: String) -> String {
        MongoDBJsonLayout.object(MongoScriptJson.members(of: collationJson).filter { $0.key != "version" })
    }
}
