//
//  ServerObjectInfo.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// One object of a kind the driver declares. Equality follows `id`, so a definition read later never
// makes a reload stop matching the row it replaces.
struct ServerObjectInfo: Identifiable, Hashable, Sendable {
    let kindId: String
    let name: String
    let schema: String?
    let identity: String?
    let detail: String?
    let isEnabled: Bool?
    let definition: String?
    let attributes: [ObjectAttribute]

    init(
        kindId: String,
        name: String,
        schema: String? = nil,
        identity: String? = nil,
        detail: String? = nil,
        isEnabled: Bool? = nil,
        definition: String? = nil,
        attributes: [ObjectAttribute] = []
    ) {
        self.kindId = kindId
        self.name = name
        self.schema = schema
        self.identity = identity
        self.detail = detail
        self.isEnabled = isEnabled
        self.definition = definition
        self.attributes = attributes
    }

    var id: String {
        let path = IdentityPath.qualified(name: name, schema: schema)
        guard let identity, !identity.isEmpty else { return "\(kindId)_\(path)" }
        return "\(kindId)_\(path)_\(identity)"
    }

    static func == (lhs: ServerObjectInfo, rhs: ServerObjectInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func adoptingSchema(_ fallback: String?) -> ServerObjectInfo {
        guard schema?.isEmpty != false, let fallback, !fallback.isEmpty else { return self }
        return ServerObjectInfo(
            kindId: kindId, name: name, schema: fallback, identity: identity, detail: detail,
            isEnabled: isEnabled, definition: definition, attributes: attributes
        )
    }
}

extension ServerObjectInfo {
    init(_ object: PluginServerObjectInfo) {
        self.init(
            kindId: object.kindId,
            name: object.name,
            schema: object.schema,
            identity: object.identity,
            detail: object.detail,
            isEnabled: object.isEnabled,
            definition: object.definition,
            attributes: object.attributes.map(ObjectAttribute.init)
        )
    }

    var pluginObject: PluginServerObjectInfo {
        PluginServerObjectInfo(
            kindId: kindId,
            name: name,
            schema: schema,
            identity: identity,
            detail: detail,
            isEnabled: isEnabled,
            definition: definition,
            attributes: attributes.map(\.pluginAttribute)
        )
    }
}
