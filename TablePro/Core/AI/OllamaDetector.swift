//
//  OllamaDetector.swift
//  TablePro
//
//  Auto-detects local Ollama installation and registers it as an AI provider.
//

import Foundation
import os

/// Detects local Ollama server and auto-registers as an AI provider
enum OllamaDetector {
    private static let logger = Logger(subsystem: "com.TablePro", category: "OllamaDetector")

    /// Check for Ollama on app launch and register if found
    @MainActor
    static func detectAndRegister() async {
        let settings = AppSettingsManager.shared.ai
        guard settings.enabled else { return }

        // Skip if an Ollama provider already exists
        if settings.providers.contains(where: { $0.type == .ollama }) {
            return
        }

        // Try to fetch models from local Ollama
        guard let models = await fetchOllamaModels(), !models.isEmpty else {
            return
        }

        let firstModel = models.first ?? ""
        let ollamaProvider = AIProviderConfig(
            name: "Ollama (Local)",
            type: .ollama,
            model: firstModel,
            endpoint: AIProviderType.ollama.defaultEndpoint,
            isEnabled: true
        )

        AppSettingsManager.shared.ai.providers.append(ollamaProvider)
        logger.info("Auto-detected Ollama with \(models.count) models, registered with model: \(firstModel)")
    }

    private static func fetchOllamaModels() async -> [String]? {
        guard let url = URL(string: "http://localhost:11434/api/tags") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]]
            else {
                return nil
            }

            return models.compactMap { $0["name"] as? String }.sorted()
        } catch {
            // Ollama not running -- expected, not an error
            logger.debug("Ollama not detected: \(error.localizedDescription)")
            return nil
        }
    }
}
