//
//  PluginObjectMapping.swift
//  TablePro
//
//  The single crossing between PluginKit's routine and trigger transfer types and the app's.
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
