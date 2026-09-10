//
//  PluginObjectMapping.swift
//  TablePro
//
//  The single crossing between PluginKit's routine, trigger and type transfer types and the app's.
//

import Foundation
import TableProPluginKit

extension ObjectAttribute {
    init(_ attribute: PluginObjectAttribute) {
        self.init(label: attribute.label, value: attribute.value)
    }

    var pluginAttribute: PluginObjectAttribute {
        PluginObjectAttribute(label: label, value: value)
    }
}

extension RoutineInfo.Kind {
    /// PluginKit ships with Library Evolution, so a plugin built against a later version can hand
    /// back a kind this build has no case for. Reading it as a function keeps that routine listed
    /// under a heading that exists rather than dropping it.
    init(_ kind: PluginRoutineKind) {
        switch kind {
        case .procedure: self = .procedure
        case .function:  self = .function
        @unknown default: self = .function
        }
    }

    var pluginKind: PluginRoutineKind {
        switch self {
        case .procedure: return .procedure
        case .function:  return .function
        }
    }
}

extension RoutineInfo {
    init(_ routine: PluginRoutineInfo) {
        self.init(
            name: routine.name,
            kind: Kind(routine.kind),
            schema: routine.schema,
            argumentSignature: routine.argumentSignature,
            returnType: routine.returnType,
            language: routine.language,
            identity: routine.identity,
            definition: routine.definition,
            attributes: routine.attributes.map(ObjectAttribute.init)
        )
    }

    /// Handed straight back to the driver that produced it, so `identity` survives the round trip
    /// and a DDL fetch addresses the exact overload the user clicked.
    var pluginRoutine: PluginRoutineInfo {
        PluginRoutineInfo(
            name: name,
            kind: kind.pluginKind,
            schema: schema,
            returnType: returnType,
            language: language,
            argumentSignature: argumentSignature,
            identity: identity,
            definition: definition,
            attributes: attributes.map(\.pluginAttribute)
        )
    }
}

extension TriggerInfo {
    init(_ trigger: PluginTriggerInfo) {
        self.init(
            name: trigger.name,
            timing: trigger.timing,
            event: trigger.event,
            statement: trigger.statement,
            enabled: trigger.enabled,
            table: trigger.table,
            schema: trigger.schema,
            orientation: trigger.orientation,
            definition: trigger.definition,
            attributes: trigger.attributes.map(ObjectAttribute.init)
        )
    }

    var pluginTrigger: PluginTriggerInfo {
        PluginTriggerInfo(
            name: name,
            table: table,
            schema: schema,
            timing: timing,
            event: event,
            orientation: orientation,
            statement: statement,
            definition: definition,
            enabled: enabled,
            attributes: attributes.map(\.pluginAttribute)
        )
    }
}

extension UserDefinedTypeInfo.Kind {
    /// A plugin built against a later PluginKit can hand back a kind this build has no case for.
    /// Reading it as `other` keeps the type listed with its definition rather than dropping it.
    init(_ kind: PluginUserDefinedTypeKind) {
        switch kind {
        case .enumeration: self = .enumeration
        case .composite:   self = .composite
        case .domain:      self = .domain
        case .range:       self = .range
        @unknown default:  self = .other
        }
    }

    var pluginKind: PluginUserDefinedTypeKind? {
        switch self {
        case .enumeration: return .enumeration
        case .composite:   return .composite
        case .domain:      return .domain
        case .range:       return .range
        case .other:       return nil
        }
    }
}

extension UserDefinedTypeInfo.Field {
    init(_ field: PluginUserDefinedTypeField) {
        self.init(name: field.name, type: field.type, collation: field.collation)
    }

    var pluginField: PluginUserDefinedTypeField {
        PluginUserDefinedTypeField(name: name, type: type, collation: collation)
    }
}

extension EnumLabelPlacement {
    var pluginPlacement: PluginEnumLabelPlacement {
        PluginEnumLabelPlacement(anchor: anchor, placesBefore: placesBefore)
    }
}

extension UserDefinedTypeInfo {
    init(_ type: PluginUserDefinedTypeInfo) {
        self.init(
            name: type.name,
            kind: Kind(type.kind),
            schema: type.schema,
            identity: type.identity,
            enumLabels: type.enumLabels,
            fields: type.fields.map(Field.init),
            baseType: type.baseType,
            columnTypeSpelling: type.columnTypeSpelling,
            definition: type.definition,
            attributes: type.attributes.map(ObjectAttribute.init)
        )
    }

    /// Handed straight back to the driver that produced it, so `identity` survives the round trip.
    /// A kind this build read as `other` goes back as the plugin's first kind only because the
    /// transfer type needs one; the driver addresses the type by identity and name, never by kind.
    var pluginType: PluginUserDefinedTypeInfo {
        PluginUserDefinedTypeInfo(
            name: name,
            kind: kind.pluginKind ?? .composite,
            schema: schema,
            identity: identity,
            enumLabels: enumLabels,
            fields: fields.map(\.pluginField),
            baseType: baseType,
            columnTypeSpelling: columnTypeSpelling,
            definition: definition,
            attributes: attributes.map(\.pluginAttribute)
        )
    }
}
