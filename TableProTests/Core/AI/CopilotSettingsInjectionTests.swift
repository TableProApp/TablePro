//
//  CopilotSettingsInjectionTests.swift
//  TableProTests
//

import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
private func makeCopilotSettings(telemetryEnabled: Bool) -> AISettings {
    let provider = AIProviderConfig(
        type: .copilot,
        model: "",
        telemetryEnabled: telemetryEnabled
    )
    return AISettings(
        providers: [provider],
        activeProviderID: provider.id
    )
}

@Suite("Copilot Settings Injection")
@MainActor
struct CopilotSettingsInjectionTests {
    @Test("CopilotService reads telemetry from injected AI settings")
    func serviceUsesInjectedTelemetrySettings() {
        let telemetryOn = CopilotService(
            aiSettingsProvider: {
                makeCopilotSettings(telemetryEnabled: true)
            }
        )
        #expect(telemetryOn.configuredTelemetryLevel == "all")

        let telemetryOff = CopilotService(
            aiSettingsProvider: {
                makeCopilotSettings(telemetryEnabled: false)
            }
        )
        #expect(telemetryOff.configuredTelemetryLevel == "off")
    }

    @Test("CopilotInlineSource availability uses injected provider")
    func inlineSourceUsesInjectedAvailabilityProvider() {
        let availableSource = CopilotInlineSource(
            documentSync: CopilotDocumentSync(),
            isCopilotAvailableProvider: { true },
            clientProvider: { nil },
            editorSettingsProvider: { EditorSettings.default }
        )
        #expect(availableSource.isAvailable == true)

        let unavailableSource = CopilotInlineSource(
            documentSync: CopilotDocumentSync(),
            isCopilotAvailableProvider: { false },
            clientProvider: { nil },
            editorSettingsProvider: { EditorSettings.default }
        )
        #expect(unavailableSource.isAvailable == false)
    }
}
