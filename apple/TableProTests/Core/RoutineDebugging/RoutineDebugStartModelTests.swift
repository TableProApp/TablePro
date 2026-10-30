//
//  RoutineDebugStartModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct RoutineDebugStartModelTests {
    private func plan(options: [ConnectionField]) -> PluginDebugPlan {
        PluginDebugPlan(
            target: PluginDebugTarget(identity: "1", name: "f", schema: nil, kindDisplayName: "Function"),
            entryPoints: [PluginDebugEntryPoint(identity: "1", displayName: "f()", parameters: [])],
            mayWrite: false,
            options: options
        )
    }

    private var protocolField: ConnectionField {
        ConnectionField(
            id: "protocol",
            label: "Protocol",
            defaultValue: "jdwp",
            fieldType: .dropdown(options: [
                .init(value: "jdwp", label: "JDWP"),
                .init(value: "dbms", label: "DBMS_DEBUG"),
            ])
        )
    }

    private var hostField: ConnectionField {
        ConnectionField(
            id: "host",
            label: "Debugger Host",
            defaultValue: "10.0.0.5",
            visibleWhen: FieldVisibilityRule(fieldId: "protocol", values: ["jdwp"])
        )
    }

    @Test("A start option shows only while the option it depends on has a matching value")
    func optionFollowsItsVisibilityRule() {
        let model = RoutineDebugStartModel(plan: plan(options: [protocolField, hostField]), rememberedOption: { _ in nil })

        #expect(model.isVisible(hostField))
        model.setOption("dbms", for: "protocol")
        #expect(!model.isVisible(hostField))
    }

    @Test("A hidden start option is not sent with the request")
    func hiddenOptionIsNotSent() {
        let model = RoutineDebugStartModel(plan: plan(options: [protocolField, hostField]), rememberedOption: { _ in nil })

        model.setOption("dbms", for: "protocol")

        #expect(model.choice()?.optionValues == ["protocol": "dbms"])
    }
}
