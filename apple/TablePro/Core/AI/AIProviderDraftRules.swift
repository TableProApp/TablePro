//
//  AIProviderDraftRules.swift
//  TablePro
//

import Foundation

/// The rules the provider sheet applies to a provider being edited, kept out of the view so they
/// can be tested.
internal enum AIProviderDraftRules {
    /// Which model a provider being set up starts on.
    ///
    /// A list sorted by name has no first choice: taking one put a router's users on whichever of
    /// several hundred models sorts first. So a model is picked only where the provider or the
    /// catalog names a default, or where there is nothing to choose between.
    internal static func initialModel(fetched: [AIModelInfo]) -> String? {
        if let marked = fetched.first(where: { $0.isProviderDefault && !$0.isDeprecated }) {
            return marked.id
        }
        return fetched.count == 1 ? fetched.first?.id : nil
    }

    // A model that always reasons gets a concrete level, since sending none runs the server's default, which can be its costliest.
    internal static func effort(
        afterPicking current: ReasoningEffort?,
        reasoning: AIReasoningSupport
    ) -> ReasoningEffort? {
        guard !reasoning.effortLevels.isEmpty || reasoning.canTurnOff else { return nil }
        if let current, reasoning.takes(current) { return current }
        guard reasoning.isMandatory else { return nil }
        return current.flatMap(reasoning.clampedEffort) ?? reasoning.preferredEffort
    }

    // A typed id is incomplete until the last keystroke; the send path fits the effort to the model anyway.
    internal static func effort(
        keeping current: ReasoningEffort?,
        reasoning: AIReasoningSupport
    ) -> ReasoningEffort? {
        guard reasoning.isMandatory, !reasoning.effortLevels.isEmpty else { return current }
        if let current, reasoning.takes(current) { return current }
        return current.flatMap(reasoning.clampedEffort) ?? reasoning.preferredEffort
    }

    // What the Reasoning picker shows: a saved level the model does not take reads as the one a send would use.
    internal static func displayedEffort(
        _ current: ReasoningEffort?,
        reasoning: AIReasoningSupport
    ) -> ReasoningEffort? {
        guard let current else { return reasoning.isMandatory ? reasoning.preferredEffort : nil }
        return reasoning.clampedEffort(current) ?? (reasoning.isMandatory ? reasoning.preferredEffort : nil)
    }

    /// Save waits for a model only while the provider's own list is there to pick one from. With
    /// no list, because the fetch is blocked or failed or the provider has not been signed in to
    /// yet, an empty model is saved as before and can be set later.
    internal static func needsModelChoice(model: String, fetched: [AIModelInfo]) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !fetched.isEmpty
    }

    /// A cleared Base URL means the default the field shows as its placeholder. Saving the empty
    /// string instead left every request failing until the next launch decoded the default back in.
    internal static func endpoint(_ typed: String, defaultEndpoint: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultEndpoint : trimmed
    }

    /// The automatic fetch reads the Base URL as typed, never the default an empty field saves as.
    /// It runs on a timer while the field is edited, and resolving an empty field to the default
    /// would send a key typed for one host to another with no click.
    internal static func modelListBlocker(
        descriptor: AIProviderDescriptor?,
        draft: AIProviderConfig,
        apiKey: String
    ) -> AIModelListFetchGate.Blocker? {
        AIModelListFetchGate.blocker(
            fetchesModelList: descriptor?.fetchesModelList == true,
            takesEndpoint: descriptor?.allowsEndpointConfiguration == true,
            endpoint: draft.endpoint,
            authStyle: draft.authStyle,
            apiKey: apiKey
        )
    }

    internal enum CatalogUpdate: Equatable {
        case store
        case remove
        case refetch
        case keep
    }

    /// What Save does with the shared model list.
    ///
    /// The sheet fetches for a draft, which can point at a server the saved provider never did, so
    /// its list reaches the catalog only on Save. When the key or Base URL changed and no list loaded
    /// for the new ones yet, the old list is dropped rather than left to describe the new server,
    /// and fetched again with what was saved.
    internal static func catalogUpdate(
        listIsCurrent: Bool,
        listIsEmpty: Bool,
        connectionChanged: Bool
    ) -> CatalogUpdate {
        if listIsCurrent {
            return listIsEmpty ? .remove : .store
        }
        return connectionChanged ? .refetch : .keep
    }
}
