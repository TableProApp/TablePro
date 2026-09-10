//
//  AnthropicModelCapabilitiesTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Anthropic model capabilities")
struct AnthropicModelCapabilitiesTests {
    init() {
        AIProviderRegistration.registerAll()
    }

    @Test("Opus 4.7 and later use adaptive thinking with the full effort ladder")
    func modernModelsAreAdaptive() {
        let models = [
            "claude-opus-4-7",
            "claude-opus-4-7-20260101",
            "claude-opus-4-8",
            "claude-opus-5",
            "claude-sonnet-5",
            "claude-fable-5",
            "claude-mythos-5"
        ]
        for model in models {
            let capabilities = AnthropicModelCapabilities.resolve(model: model)
            #expect(capabilities.thinkingMode == .adaptive, "\(model) should be adaptive")
            #expect(
                capabilities.effortLevels == [.low, .medium, .high, .xhigh],
                "\(model) should offer the full ladder"
            )
        }
    }

    @Test("The 4.6 family is adaptive but has no xhigh effort level")
    func fourSixFamilyExcludesExtraHigh() {
        for model in ["claude-opus-4-6", "claude-sonnet-4-6", "claude-sonnet-4-6-20251101"] {
            let capabilities = AnthropicModelCapabilities.resolve(model: model)
            #expect(capabilities.thinkingMode == .adaptive, "\(model) should be adaptive")
            #expect(!capabilities.effortLevels.contains(.xhigh), "\(model) must not offer xhigh")
            #expect(capabilities.effortLevels.contains(.high), "\(model) should still offer high")
        }
    }

    @Test("Pre-4.6 models use a thinking budget, never the effort parameter")
    func legacyModelsAreBudgeted() {
        let models = [
            "claude-haiku-4-5",
            "claude-haiku-4-5-20251001",
            "claude-sonnet-4-5",
            "claude-sonnet-4-5-20250929",
            "claude-opus-4-5",
            "claude-opus-4-1",
            "claude-opus-4-20250514",
            "claude-sonnet-4-20250514",
            "claude-3-haiku-20240307"
        ]
        for model in models {
            let capabilities = AnthropicModelCapabilities.resolve(model: model)
            #expect(capabilities.thinkingMode == .budgeted, "\(model) should be budgeted")
            #expect(!capabilities.sendsEffortParameter, "\(model) must not send output_config.effort")
        }
    }

    @Test("Budgeted models keep an effort picker, because effort selects the thinking budget")
    func budgetedModelsKeepEffortPicker() {
        let capabilities = AnthropicModelCapabilities.resolve(model: "claude-haiku-4-5")
        #expect(capabilities.effortLevels == [.low, .medium, .high])
    }

    @Test("No Claude model advertises xhigh unless its API accepts it")
    func extraHighOnlyWhereSupported() {
        let withExtraHigh = ["claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-sonnet-5"]
        for model in withExtraHigh {
            #expect(AnthropicModelCapabilities.effortLevels(forModel: model).contains(.xhigh), "\(model)")
        }

        let withoutExtraHigh = ["claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5", "claude-opus-4-5"]
        for model in withoutExtraHigh {
            #expect(!AnthropicModelCapabilities.effortLevels(forModel: model).contains(.xhigh), "\(model)")
        }
    }

    @Test("No Claude model advertises Minimal, which has no distinct meaning on this API")
    func minimalIsNeverAdvertised() {
        let models = [
            "claude-opus-5", "claude-opus-4-7", "claude-sonnet-4-6",
            "claude-haiku-4-5", "claude-opus-4-5", "claude-something-9"
        ]
        for model in models {
            #expect(!AnthropicModelCapabilities.effortLevels(forModel: model).contains(.minimal), "\(model)")
        }
    }

    @Test("The thinking budget rises with effort and never inverts")
    func budgetLadderIsMonotonic() {
        let budgets = ReasoningEffort.allCases.map(\.anthropicBudgetTokens)
        #expect(budgets == budgets.sorted(), "a lower effort must not ask for a larger budget")
        #expect(
            ReasoningEffort.minimal.anthropicBudgetTokens >= AnthropicModelCapabilities.minimumThinkingBudgetTokens,
            "every level must clear the API minimum"
        )
    }

    @Test("Dotted model identifiers resolve the same as dashed ones")
    func dottedIdentifiersNormalize() {
        #expect(
            AnthropicModelCapabilities.resolve(model: "claude-sonnet-4.6")
                == AnthropicModelCapabilities.resolve(model: "claude-sonnet-4-6")
        )
        #expect(
            AnthropicModelCapabilities.resolve(model: "claude-haiku-4.5")
                == AnthropicModelCapabilities.resolve(model: "claude-haiku-4-5")
        )
    }

    @Test("An unrecognised model falls back to adaptive, which every current model accepts")
    func unknownModelDefaultsToAdaptive() {
        let capabilities = AnthropicModelCapabilities.resolve(model: "claude-something-9")
        #expect(capabilities.thinkingMode == .adaptive)
        #expect(capabilities.effortLevels == [.low, .medium, .high, .xhigh])
    }

    @Test("Effort clamps down to the highest level the model supports")
    func effortClampsToSupportedLevel() {
        let fourSix = AnthropicModelCapabilities.resolve(model: "claude-sonnet-4-6")
        #expect(fourSix.clampedEffort(.xhigh) == .high)
        #expect(fourSix.clampedEffort(.medium) == .medium)

        let modern = AnthropicModelCapabilities.resolve(model: "claude-opus-5")
        #expect(modern.clampedEffort(.xhigh) == .xhigh)
    }

    @Test("Claude effort levels advertised by the registry match the capability table")
    func registryAgreesWithCapabilityTable() throws {
        let descriptor = try #require(AIProviderRegistry.shared.descriptor(for: AIProviderType.claude.rawValue))

        for model in ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5", "claude-opus-5"] {
            #expect(
                descriptor.supportedEffortLevels(forModelID: model)
                    == AnthropicModelCapabilities.effortLevels(forModel: model),
                "\(model) advertises levels the wire encoder disagrees with"
            )
        }
    }

    @Test("Effort wire values use the API's spelling")
    func effortWireValues() {
        #expect(ReasoningEffort.minimal.anthropicEffortValue == "low")
        #expect(ReasoningEffort.low.anthropicEffortValue == "low")
        #expect(ReasoningEffort.medium.anthropicEffortValue == "medium")
        #expect(ReasoningEffort.high.anthropicEffortValue == "high")
        #expect(ReasoningEffort.xhigh.anthropicEffortValue == "xhigh")
    }
}
