//
//  AIChatViewModelOnDeviceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

extension GlobalStateSuites {
    @Suite(.appSettings {
        $0.ai.enabled = true
        $0.ai.providers = []
        $0.ai.activeProviderID = nil
        $0.ai.useAppleIntelligence = true
        $0.ai.includeSchema = false
        $0.ai.defaultConnectionPolicy = .alwaysAllow
    })
    @MainActor
    struct AIChatViewModelOnDeviceTests {
        private static let noProvider = String(localized: "No AI provider configured. Go to Settings > AI to add one.")

        private func makeViewModel(_ model: FakeOnDeviceModel) -> AIChatViewModel {
            let viewModel = AIChatViewModel()
            viewModel.connection = TestFixtures.makeConnection(type: .mysql)
            viewModel.onDeviceModel = model
            return viewModel
        }

        private func request(_ statement: String = "SELECT id FROM orders") -> AIQueryRequest {
            AIQueryRequest(action: .review, statement: statement, scope: nil, databaseType: .mysql)
        }

        private func roles(_ viewModel: AIChatViewModel) -> [ChatRole] {
            viewModel.messages.map { $0.role }
        }

        @Test("A query action is answered on this Mac, with no provider set up")
        func answersOnDevice() async throws {
            let model = FakeOnDeviceModel()
            let viewModel = makeViewModel(model)

            viewModel.runQueryAction(request())
            await viewModel.streamingTask?.value

            let reply = try #require(viewModel.messages.last)
            #expect(roles(viewModel) == [.user, .assistant])
            #expect(reply.plainText == "Looks fine.")
            #expect(reply.modelId == AppleIntelligenceAvailability.displayName)
            #expect(viewModel.errorMessage == nil)
            #expect(!viewModel.isStreaming)
            let sent = try #require(model.streamedRequests.first)
            #expect(sent.request.prompt.contains("SELECT id FROM orders"))
            #expect(sent.request.instructions.contains("MySQL"))
            #expect(!sent.request.instructions.contains(WalkthroughEnvelopeParser.openFence))
        }

        @Test("A request too large is refused before generation, keeps the action and offers the provider")
        func tooLargeIsRefused() async throws {
            let model = FakeOnDeviceModel(contextSize: 1_500) { _ in 1_000 }
            let viewModel = makeViewModel(model)

            viewModel.runQueryAction(request())
            await viewModel.streamingTask?.value

            #expect(model.streamedRequests.isEmpty)
            #expect(roles(viewModel) == [.user])
            #expect(viewModel.errorMessage?.contains("Apple Intelligence") == true)
            #expect(viewModel.onDeviceRefusal?.turnID == viewModel.messages.last?.id)
            #expect(!viewModel.isStreaming)
        }

        @Test("Sending a refused action on answers the same turn through the provider path")
        func refusedTurnGoesToProvider() async throws {
            let model = FakeOnDeviceModel(contextSize: 1_500) { _ in 1_000 }
            let viewModel = makeViewModel(model)
            viewModel.runQueryAction(request())
            await viewModel.streamingTask?.value

            viewModel.sendRefusedTurnToProvider()

            #expect(model.countedRequests.count == 1)
            #expect(viewModel.onDeviceTurnID == nil)
            #expect(viewModel.onDeviceRefusal == nil)
            #expect(viewModel.errorMessage == Self.noProvider)
        }

        @Test("A follow-up in the same conversation goes to the provider, never the device")
        func followUpLeavesTheDevice() async throws {
            let model = FakeOnDeviceModel()
            let viewModel = makeViewModel(model)
            viewModel.runQueryAction(request())
            await viewModel.streamingTask?.value

            viewModel.inputText = "Why is that?"
            viewModel.sendMessage()

            #expect(model.streamedRequests.count == 1)
            #expect(viewModel.errorMessage == Self.noProvider)
        }

        @Test("Regenerating an on-device answer asks the device again")
        func regenerateStaysOnDevice() async throws {
            let model = FakeOnDeviceModel()
            let viewModel = makeViewModel(model)
            viewModel.runQueryAction(request())
            await viewModel.streamingTask?.value

            viewModel.regenerate()
            await viewModel.streamingTask?.value

            #expect(model.streamedRequests.count == 2)
            #expect(roles(viewModel) == [.user, .assistant])
        }

        @Test("Regenerating a restored on-device answer stays on the device")
        func regenerateRestoredAnswerStaysOnDevice() async throws {
            let model = FakeOnDeviceModel()
            let viewModel = makeViewModel(model)
            viewModel.messages = [
                ChatTurn(role: .user, blocks: [.text("Review this SQL query.")]),
                ChatTurn(
                    role: .assistant,
                    blocks: [.text("Looks fine.")],
                    modelId: AppleIntelligenceAvailability.displayName,
                    providerId: AppleIntelligenceAvailability.providerID
                )
            ]

            viewModel.regenerate()
            await viewModel.streamingTask?.value

            #expect(model.streamedRequests.count == 1)
            #expect(viewModel.errorMessage == nil)
            #expect(roles(viewModel) == [.user, .assistant])
        }

        @Test("With the model unavailable the action says why and sends nothing")
        func unavailableExplains() {
            let unavailable = AppleIntelligenceAvailability.unavailable(.appleIntelligenceNotEnabled)
            let model = FakeOnDeviceModel(availability: unavailable)
            let viewModel = makeViewModel(model)

            viewModel.runQueryAction(request())

            #expect(viewModel.messages.isEmpty)
            #expect(viewModel.errorMessage == unavailable.unavailableExplanation)
            #expect(model.countedRequests.isEmpty)
        }

        @Test("Ask Each Time asks before the device reads anything", .appSettings {
            $0.ai.defaultConnectionPolicy = .askEachTime
        })
        func askEachTimeAsksFirst() async throws {
            let model = FakeOnDeviceModel()
            let viewModel = makeViewModel(model)

            viewModel.runQueryAction(request())

            #expect(viewModel.showAIAccessConfirmation)
            #expect(model.countedRequests.isEmpty)

            viewModel.confirmAIAccess()
            await viewModel.streamingTask?.value

            #expect(model.streamedRequests.count == 1)
            #expect(roles(viewModel) == [.user, .assistant])
        }

        @Test("With the setting off the action goes to the provider path", .appSettings {
            $0.ai.useAppleIntelligence = false
        })
        func settingOffUsesProvider() {
            let model = FakeOnDeviceModel()
            let viewModel = makeViewModel(model)

            viewModel.runQueryAction(request())

            #expect(model.countedRequests.isEmpty)
            #expect(viewModel.errorMessage == Self.noProvider)
        }
    }
}
