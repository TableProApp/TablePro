//
//  DatabaseObjectRef.swift
//  TablePro
//
//  Everything needed to find one routine, trigger, type or view again and read its source.
//

import Foundation

enum DatabaseObjectKind: String, Codable, Sendable, Hashable {
    case procedure
    case function
    case trigger
    case userType
    case view
    case materializedView
    // A kind the driver declares; the ref's `serverKind` says which one.
    case serverObject

    var sidebarObjectKind: SidebarObjectKind? {
        switch self {
        case .procedure:        return .procedure
        case .function:         return .function
        case .trigger:          return .trigger
        case .userType:         return .type
        case .view:             return .view
        case .materializedView: return .materializedView
        case .serverObject:     return nil
        }
    }

    /// The kind a table listing row opens as, or nil for a row whose source is its table DDL.
    init?(tableType: TableInfo.TableType) {
        switch tableType {
        case .view: self = .view
        case .materializedView: self = .materializedView
        case .table, .foreignTable, .systemTable, .partitionedTable, .externalTable, .sequence:
            return nil
        }
    }

    var displayName: String {
        sidebarObjectKind?.displayName ?? String(localized: "Object")
    }

    var iconName: String {
        sidebarObjectKind?.iconName ?? "shippingbox"
    }
}

struct ServerObjectKindRef: Hashable, Codable, Sendable {
    let id: String
    let displayName: String
    let iconName: String
    // Optional so a ref written without it decodes, and reads as a container kind.
    let scope: SidebarServerObjectKind.Scope?

    init(id: String, displayName: String, iconName: String, scope: SidebarServerObjectKind.Scope? = nil) {
        self.id = id
        self.displayName = displayName
        self.iconName = iconName
        self.scope = scope
    }

    init(_ kind: SidebarServerObjectKind) {
        self.init(id: kind.id, displayName: kind.displayName, iconName: kind.iconName, scope: kind.scope)
    }
}

/// This survives a relaunch, so it carries addressing only and never the source text. A restored
/// viewer refetches, which is also what makes it show the current definition rather than the one
/// that was on screen when the app quit.
struct DatabaseObjectRef: Hashable, Codable, Sendable {
    let kind: DatabaseObjectKind
    let name: String
    let database: String
    let schema: String?

    /// The owning table. Triggers only.
    let table: String?

    /// The driver's own key for this routine or type, opaque here.
    let identity: String?
    let argumentSignature: String?

    /// Which kind of named type this is. Types only, and optional so a tab persisted before types
    /// existed still decodes.
    let typeKind: UserDefinedTypeInfo.Kind?

    /// What the sidebar's listing already learned about the object. Carried so the viewer does not
    /// re-list an entire schema to recover it, and short enough to persist with the tab.
    let attributes: [ObjectAttribute]

    // Server objects only, and optional so a tab persisted before them still decodes.
    let serverKind: ServerObjectKindRef?

    init(
        kind: DatabaseObjectKind,
        name: String,
        database: String,
        schema: String? = nil,
        table: String? = nil,
        identity: String? = nil,
        argumentSignature: String? = nil,
        typeKind: UserDefinedTypeInfo.Kind? = nil,
        attributes: [ObjectAttribute] = [],
        serverKind: ServerObjectKindRef? = nil
    ) {
        self.kind = kind
        self.name = name
        self.database = database
        self.schema = schema
        self.table = table
        self.identity = identity
        self.argumentSignature = argumentSignature
        self.typeKind = typeKind
        self.attributes = attributes
        self.serverKind = serverKind
    }

    init(routine: RoutineInfo, database: String) {
        self.init(
            kind: routine.kind == .procedure ? .procedure : .function,
            name: routine.name,
            database: database,
            schema: routine.schema,
            identity: routine.identity,
            argumentSignature: routine.argumentSignature,
            attributes: routine.attributes
        )
    }

    init(trigger: TriggerInfo, database: String) {
        self.init(
            kind: .trigger,
            name: trigger.name,
            database: database,
            schema: trigger.schema,
            table: trigger.table,
            attributes: trigger.attributes
        )
    }

    /// A view or materialized view, whose source is read the way the Structure tab reads it.
    init?(relation table: TableInfo, database: String, schema: String?) {
        guard let kind = DatabaseObjectKind(tableType: table.type) else { return nil }
        self.init(kind: kind, name: table.name, database: database, schema: schema)
    }

    init(userType: UserDefinedTypeInfo, database: String) {
        self.init(
            kind: .userType,
            name: userType.name,
            database: database,
            schema: userType.schema,
            identity: userType.identity,
            typeKind: userType.kind,
            attributes: userType.attributes
        )
    }

    init(serverObject: ServerObjectInfo, kind: SidebarServerObjectKind, database: String) {
        self.init(
            kind: .serverObject,
            name: serverObject.name,
            database: database,
            schema: serverObject.schema,
            identity: serverObject.identity,
            attributes: serverObject.attributes,
            serverKind: ServerObjectKindRef(kind)
        )
    }

    // Enough to tell two overloads, or two same-named triggers on different tables, apart.
    var displayIdentity: String {
        switch kind {
        case .procedure, .function:
            guard let argumentSignature, !argumentSignature.isEmpty else { return qualifiedName }
            return "\(qualifiedName)\(argumentSignature)"
        case .trigger:
            guard let table, !table.isEmpty else { return qualifiedName }
            return String(format: String(localized: "%1$@ on %2$@"), qualifiedName, table)
        case .userType, .view, .materializedView:
            return qualifiedName
        case .serverObject:
            return isDatabaseScoped ? name : qualifiedName
        }
    }

    // A database-wide object's schema is where it keeps its members, never part of its name.
    var isDatabaseScoped: Bool {
        kind == .serverObject && serverKind?.scope == .database
    }

    // A type names its own kind, since an enum and a domain are edited differently.
    var kindDisplayName: String {
        switch kind {
        case .userType: return (typeKind ?? .other).displayName
        case .serverObject: return serverKind?.displayName ?? kind.displayName
        case .procedure, .function, .trigger, .view, .materializedView: return kind.displayName
        }
    }

    var kindIconName: String {
        switch kind {
        case .userType: return (typeKind ?? .other).iconName
        case .serverObject: return serverKind?.iconName ?? kind.iconName
        case .procedure, .function, .trigger, .view, .materializedView: return kind.iconName
        }
    }

    var qualifiedName: String {
        guard let schema, !schema.isEmpty else { return name }
        return "\(schema).\(name)"
    }

    // An empty database is server-scoped; resolving it once keeps the tab-dedup key and the loader's scope agreeing.
    func resolvingDatabase(_ fallback: String) -> DatabaseObjectRef {
        guard database.isEmpty, !fallback.isEmpty else { return self }
        return DatabaseObjectRef(
            kind: kind,
            name: name,
            database: fallback,
            schema: schema,
            table: table,
            identity: identity,
            argumentSignature: argumentSignature,
            typeKind: typeKind,
            attributes: attributes,
            serverKind: serverKind
        )
    }

    var routine: RoutineInfo? {
        switch kind {
        case .procedure, .function:
            return RoutineInfo(
                name: name,
                kind: kind == .procedure ? .procedure : .function,
                schema: schema,
                argumentSignature: argumentSignature,
                identity: identity
            )
        case .trigger, .userType, .view, .materializedView, .serverObject:
            return nil
        }
    }

    var trigger: TriggerInfo? {
        guard kind == .trigger else { return nil }
        return TriggerInfo(name: name, timing: "", event: "", statement: "", table: table, schema: schema)
    }

    var userType: UserDefinedTypeInfo? {
        guard kind == .userType else { return nil }
        return UserDefinedTypeInfo(
            name: name,
            kind: typeKind ?? .other,
            schema: schema,
            identity: identity,
            attributes: attributes
        )
    }

    var serverObject: ServerObjectInfo? {
        guard kind == .serverObject, let serverKind else { return nil }
        return ServerObjectInfo(
            kindId: serverKind.id,
            name: name,
            schema: schema,
            identity: identity,
            attributes: attributes
        )
    }

    // Attributes change with a comment edit, and some drivers fill identity with a value many objects share.
    func namesSameObject(as other: DatabaseObjectRef) -> Bool {
        guard kind == other.kind,
              database == other.database,
              name == other.name,
              schema == other.schema,
              table == other.table,
              argumentSignature == other.argumentSignature,
              serverKind?.id == other.serverKind?.id
        else { return false }
        guard let identity, let otherIdentity = other.identity else { return true }
        return identity == otherIdentity
    }

    /// A file name for Export, safe on every filesystem the save panel can reach.
    var suggestedFileName: String {
        let base = [schema, table, name].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "_")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        let cleaned = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return "\(cleaned.isEmpty ? "object" : cleaned).sql"
    }
}
