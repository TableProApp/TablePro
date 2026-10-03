//
//  OpenAICompatibleProvider+Models.swift
//  TablePro
//

import Foundation

extension OpenAICompatibleProvider {
    /// Routers say more about a model than its id, in two shapes: Requesty's flat `supports_*`
    /// flags, and OpenRouter's `architecture` and `supported_parameters`. A plain OpenAI list has
    /// neither, and then nothing is claimed about the model.
    static func decodeModel(_ json: [String: Any]) -> AIModelInfo? {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let topProvider = json["top_provider"] as? [String: Any]
        return AIModelInfo(
            id: id,
            contextWindow: json["context_window"] as? Int ?? json["context_length"] as? Int,
            maxOutputTokens: json["max_output_tokens"] as? Int ?? topProvider?["max_completion_tokens"] as? Int,
            modalities: decodeModalities(json),
            reasoning: decodeReasoning(json)
        )
    }

    private static func decodeModalities(_ json: [String: Any]) -> Set<AIModality> {
        if let vision = json["supports_vision"] as? Bool {
            return vision ? [.text, .image] : [.text]
        }
        let architecture = json["architecture"] as? [String: Any]
        if let inputs = architecture?["input_modalities"] as? [String] {
            return inputs.contains("image") ? [.text, .image] : [.text]
        }
        return []
    }

    private static func decodeReasoning(_ json: [String: Any]) -> AIReasoningSupport? {
        let supported: Bool
        if let flag = json["supports_reasoning"] as? Bool {
            supported = flag
        } else if let parameters = json["supported_parameters"] as? [String] {
            supported = parameters.contains("reasoning")
        } else {
            return nil
        }
        guard supported else { return .unsupported }
        return AIReasoningSupport(mode: .effortOnly, effortLevels: [.low, .medium, .high])
    }
}
