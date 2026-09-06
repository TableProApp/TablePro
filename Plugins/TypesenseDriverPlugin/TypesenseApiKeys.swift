//
//  TypesenseApiKeys.swift
//  TypesenseDriverPlugin
//
//  Typesense API keys, projected onto the app's principal and privilege model.
//

import Foundation
import TableProPluginKit

struct TypesenseApiKey: Equatable {
    let id: Int
    let description: String
    let actions: [String]
    let collections: [String]
    let valuePrefix: String?
    let expiresAt: Int?

    /// A key has no name of its own. The description is what the person typed, and it is the only
    /// thing that reads as a name in a list; the id keeps two keys with the same description apart.
    var displayName: String {
        description.isEmpty ? "Key #\(id)" : "\(description) (#\(id))"
    }
}

enum TypesenseApiKeys {
    static let allCollections = "*"

    /// The actions Typesense documents, grouped the way the privilege editor shows them. `*` is a
    /// real action value meaning every action, not a wildcard the app expands.
    static let actionCatalog: [(name: String, label: String, category: String)] = [
        ("*", "All actions", "General"),
        ("documents:search", "Search documents", "Documents"),
        ("documents:get", "Get a document", "Documents"),
        ("documents:create", "Create documents", "Documents"),
        ("documents:upsert", "Upsert documents", "Documents"),
        ("documents:update", "Update documents", "Documents"),
        ("documents:delete", "Delete documents", "Documents"),
        ("documents:import", "Import documents", "Documents"),
        ("documents:export", "Export documents", "Documents"),
        ("documents:*", "All document actions", "Documents"),
        ("collections:list", "List collections", "Collections"),
        ("collections:get", "Get a collection", "Collections"),
        ("collections:create", "Create collections", "Collections"),
        ("collections:delete", "Delete collections", "Collections"),
        ("collections:*", "All collection actions", "Collections"),
        ("aliases:*", "All alias actions", "Aliases"),
        ("synonyms:*", "All synonym actions", "Synonyms"),
        ("overrides:*", "All override actions", "Curation"),
        ("keys:*", "All key actions", "Keys"),
        ("metrics.json:list", "Read metrics", "Operations"),
        ("stats.json:list", "Read stats", "Operations"),
        ("debug:list", "Read debug info", "Operations"),
    ]

    // MARK: - Decoding

    static func keys(from json: Any?) -> [TypesenseApiKey] {
        guard let object = json as? [String: Any],
              let raw = object["keys"] as? [[String: Any]] else { return [] }
        return raw.compactMap(key(from:))
    }

    static func key(from json: [String: Any]) -> TypesenseApiKey? {
        guard let id = (json["id"] as? NSNumber)?.intValue else { return nil }
        return TypesenseApiKey(
            id: id,
            description: (json["description"] as? String) ?? "",
            actions: (json["actions"] as? [String]) ?? [],
            collections: (json["collections"] as? [String]) ?? [],
            valuePrefix: json["value_prefix"] as? String,
            expiresAt: (json["expires_at"] as? NSNumber)?.intValue
        )
    }

    /// The key id has to survive the round trip through `PluginPrincipalRef`, which carries only a
    /// name, so it is parsed back out of the display name rather than tracked on the side.
    static func id(fromDisplayName name: String) -> Int? {
        guard let open = name.lastIndex(of: "#") else { return Int(name) }
        let digits = name[name.index(after: open)...].prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: - Projection

    static func principal(for key: TypesenseApiKey) -> PluginPrincipalInfo {
        PluginPrincipalInfo(
            ref: PluginPrincipalRef(name: key.displayName),
            isRole: false,
            canLogin: true,
            attributes: [],
            memberOf: [],
            connectionLimit: nil,
            comment: comment(for: key)
        )
    }

    static func comment(for key: TypesenseApiKey) -> String? {
        var parts: [String] = []
        if let prefix = key.valuePrefix, !prefix.isEmpty {
            parts.append(String(format: String(localized: "Starts with %@"), prefix))
        }
        if key.collections.isEmpty || key.collections == [allCollections] {
            parts.append(String(localized: "All collections"))
        } else {
            parts.append(key.collections.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A Typesense key carries actions and a collection list, and the pair is the grant: every
    /// action applies to every collection the key names. `*` means the whole server.
    static func grants(for key: TypesenseApiKey, database: String) -> [PluginGrantInfo] {
        let scopes: [PluginPrivilegeScope] = key.collections.isEmpty || key.collections == [allCollections]
            ? [.server]
            : key.collections.map { .table(database: database, schema: nil, table: $0) }
        return key.actions.flatMap { action in
            scopes.map { PluginGrantInfo(privilege: action, scope: $0, isGrantable: false) }
        }
    }

    static var catalog: PluginPrivilegeCatalog {
        let descriptors = actionCatalog.map {
            PluginPrivilegeDescriptor(name: $0.name, label: $0.label, category: $0.category)
        }
        return PluginPrivilegeCatalog(
            serverPrivileges: descriptors,
            databasePrivileges: descriptors,
            schemaPrivileges: [],
            tablePrivileges: descriptors,
            columnPrivileges: [],
            supportsDynamicPrivileges: false
        )
    }

    // MARK: - Requests

    static func createRequest(description: String, actions: [String], collections: [String]) -> TypesenseWriteRequest? {
        let payload: [String: Any] = [
            "description": description,
            "actions": actions.isEmpty ? ["documents:search"] : actions,
            "collections": collections.isEmpty ? [allCollections] : collections,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let body = String(data: data, encoding: .utf8)
        else { return nil }
        return TypesenseWriteRequest(method: "POST", path: "/keys", body: body)
    }

    static func deleteRequest(id: Int) -> TypesenseWriteRequest {
        TypesenseWriteRequest(method: "DELETE", path: "/keys/\(id)", body: nil)
    }
}
