//
//  DatabaseObjectRef.swift
//  TablePro
//
//  Everything needed to find one routine, trigger or type again and read its source.
//

import Foundation

enum DatabaseObjectKind: String, Codable, Sendable, Hashable {
    case procedure
    case function
    case trigger
    case userType

    var sidebarObjectKind: SidebarObjectKind {
        switch self {
        case .procedure: return .procedure
        case .function:  return .function
        case .trigger:   return .trigger
        case .userType:  return .type
        }
    }

    var displayName: String {
        sidebarObjectKind.displayName
    }

    var iconName: String {
        sidebarObjectKind.iconName
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

    init(
        kind: DatabaseObjectKind,
        name: String,
        database: String,
        schema: String? = nil,
        table: String? = nil,
        identity: String? = nil,
        argumentSignature: String? = nil,
        typeKind: UserDefinedTypeInfo.Kind? = nil,
        attributes: [ObjectAttribute] = []
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

    /// What the tab is titled and what the viewer's header shows: enough to tell two overloads
    /// apart, and enough to tell two same-named triggers on different tables apart.
    var displayIdentity: String {
        switch kind {
        case .procedure, .function:
            guard let argumentSignature, !argumentSignature.isEmpty else { return qualifiedName }
            return "\(qualifiedName)\(argumentSignature)"
        case .trigger:
            guard let table, !table.isEmpty else { return qualifiedName }
            return String(format: String(localized: "%1$@ on %2$@"), qualifiedName, table)
        case .userType:
            return qualifiedName
        }
    }

    /// The kind's name for the header capsule. A type says which kind of type it is, because an
    /// enum and a domain are edited differently and the reader should know which one opened.
    var kindDisplayName: String {
        guard kind == .userType else { return kind.displayName }
        return (typeKind ?? .other).displayName
    }

    var kindIconName: String {
        guard kind == .userType else { return kind.iconName }
        return (typeKind ?? .other).iconName
    }

    var qualifiedName: String {
        guard let schema, !schema.isEmpty else { return name }
        return "\(schema).\(name)"
    }

    /// A ref built where no database was selected carries an empty one, and an empty database is
    /// server-scoped. Resolving it once keeps the tab-dedup key and the loader's scope agreeing.
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
            attributes: attributes
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
        case .trigger, .userType:
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

    /// A file name for Export, safe on every filesystem the save panel can reach.
    var suggestedFileName: String {
        let base = [schema, table, name].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "_")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        let cleaned = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return "\(cleaned.isEmpty ? "object" : cleaned).sql"
    }
}
