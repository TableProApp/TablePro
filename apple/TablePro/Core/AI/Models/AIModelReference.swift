//
//  AIModelReference.swift
//  TablePro
//

import Foundation
import os

// Facts a provider's own model list leaves out, from core/crates/ai/ai-models.json (core ADR 0049).
struct AIModelReferenceFile: Decodable, Sendable, Equatable {
    static let supportedSchema = 1

    struct Reasoning: Decodable, Sendable, Equatable {
        let efforts: [String]?
        let toggle: Bool?
        let budgetMin: Int?
        let defaultEffort: String?

        enum CodingKeys: String, CodingKey {
            case efforts, toggle
            case budgetMin = "budget_min"
            case defaultEffort = "default"
        }
    }

    struct Model: Decodable, Sendable, Equatable {
        let id: String
        let name: String?
        let released: String?
        let deprecated: Bool?
        let output: Int?
        let images: Bool?
        let apis: [String]?
        let reasoning: Reasoning?
    }

    struct Provider: Decodable, Sendable, Equatable {
        let defaultModel: String?
        let clientVersion: String?
        let models: [Model]

        enum CodingKeys: String, CodingKey {
            case defaultModel = "default"
            case clientVersion = "client_version"
            case models
        }

        init(defaultModel: String?, clientVersion: String? = nil, models: [Model]) {
            self.defaultModel = defaultModel
            self.clientVersion = clientVersion
            self.models = models
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
            clientVersion = try container.decodeIfPresent(String.self, forKey: .clientVersion)
            let entries = try container.decodeIfPresent([Lossy<Model>].self, forKey: .models) ?? []
            models = entries.compactMap(\.value)
        }

        func model(_ id: String) -> Model? {
            for key in AIModelMerge.lookupKeys(id) {
                if let model = models.first(where: { $0.id == key }) {
                    return model
                }
            }
            return nil
        }
    }

    let schema: Int
    let generated: Date
    let providers: [String: Provider]

    static func decode(_ data: Data) throws -> AIModelReferenceFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(AIModelReferenceFile.self, from: data)
        guard file.schema == supportedSchema else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown schema \(file.schema)"))
        }
        return file
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension AIModelReferenceFile.Model {
    static func date(_ day: String?) -> Date? {
        guard let day else { return nil }
        return try? Date(day, strategy: Date.ISO8601FormatStyle().year().month().day())
    }

    func info(providerKey: String) -> AIModelInfo {
        AIModelInfo(
            id: id,
            displayName: name,
            maxOutputTokens: output,
            modalities: images.map { $0 ? [.text, .image] : [.text] } ?? [],
            reasoning: reasoningSupport(providerKey: providerKey),
            isDeprecated: deprecated ?? false,
            released: Self.date(released)
        )
    }

    // A listed model with no reasoning entry does not reason; one with an entry but no levels is unknown.
    private func reasoningSupport(providerKey: String) -> AIReasoningSupport? {
        guard let reasoning else { return .unsupported }
        let wire = reasoning.efforts ?? []
        let levels = ReasoningEffort.levels(fromWire: wire)
        let canTurnOff = (reasoning.toggle ?? false) || wire.contains { $0.lowercased() == "none" }
        let mode: AIReasoningMode
        if providerKey == AIModelSource.anthropicKey {
            // The catalog cannot tell adaptive thinking apart: Opus 4.5 lists effort and a budget and takes only the budget.
            if reasoning.budgetMin != nil {
                mode = .budgeted
            } else if !levels.isEmpty {
                mode = .adaptive
            } else {
                return nil
            }
        } else {
            guard !levels.isEmpty else { return nil }
            mode = .effortOnly
        }
        return AIReasoningSupport(
            mode: mode,
            effortLevels: mode == .budgeted ? [.low, .medium, .high] : levels,
            defaultEffort: reasoning.defaultEffort.flatMap(ReasoningEffort.init(wireValue:)),
            isMandatory: mode != .budgeted,
            canTurnOff: canTurnOff && mode != .budgeted
        )
    }
}

// Where a provider configuration's models are looked up in the catalog, and how its list is merged with it.
struct AIModelSource: Equatable, Sendable {
    static let anthropicKey = "anthropic"

    let key: String?
    let api: String?
    // A vendor list with ids only, where an id the catalog does not know is not shown.
    let hidesUnknown: Bool
    // The provider documents its list order.
    let liveOrdered: Bool

    static let unlisted = AIModelSource(key: nil, api: nil, hidesUnknown: false, liveOrdered: true)

    var readsClientVersion: Bool { key == ChatGPTCodex.catalogKey }

    init(key: String?, api: String?, hidesUnknown: Bool, liveOrdered: Bool) {
        self.key = key
        self.api = api
        self.hidesUnknown = hidesUnknown
        self.liveOrdered = liveOrdered
    }

    init(config: AIProviderConfig) {
        let host = AIEndpoint(config.endpoint, style: config.type.endpointStyle)?.apiBase.host?.lowercased()
        if config.preset?.id == AIProviderPreset.meta.id {
            self.init(key: "meta", api: "chat-completions", hidesUnknown: host == "api.meta.ai", liveOrdered: false)
            return
        }
        switch config.type {
        case .claude:
            self.init(key: Self.anthropicKey, api: "messages", hidesUnknown: false, liveOrdered: true)
        case .openAI:
            let vendor = host == "api.openai.com" || host?.hasSuffix(".api.openai.com") == true
            self.init(key: "openai", api: "responses", hidesUnknown: vendor, liveOrdered: false)
        case .chatgptCodex:
            self.init(key: ChatGPTCodex.catalogKey, api: nil, hidesUnknown: false, liveOrdered: true)
        case .gemini:
            self.init(key: "google", api: nil, hidesUnknown: false, liveOrdered: false)
        case .xai:
            self.init(key: "xai", api: nil, hidesUnknown: false, liveOrdered: false)
        case .copilot, .claudeAgent, .openRouter, .ollama, .llamaCpp, .mlx, .openCode, .custom:
            self = .unlisted
        }
    }
}

final class AIModelReference: @unchecked Sendable {
    static let shared = AIModelReference(
        bundle: .main,
        session: makeDefaultSession(),
        savedURL: directory.appendingPathComponent("models-v1.json")
    )

    private static var directory: URL {
        AppStorageEnvironment.shared.supportDirectory.appendingPathComponent("AIModels", isDirectory: true)
    }

    static let remoteURL: URL = {
        guard let url = URL(string: "https://updates.tablepro.app/ai/models-v1.json") else {
            preconditionFailure("The AI model catalog URL does not parse")
        }
        return url
    }()

    private static let logger = Logger(subsystem: "com.TablePro", category: "AIModelReference")

    private let lock = NSLock()
    private var file: AIModelReferenceFile?
    private var refreshTask: Task<Void, Never>?
    // Failures count too, so an unreachable host is not asked again on every list (ADR 0049).
    private var lastAttempt: Date?
    private static let refreshInterval: TimeInterval = 60 * 60
    private let session: URLSession?
    // The last copy accepted, kept apart from the HTTP cache, which a rejected answer can overwrite.
    private let savedURL: URL?

    init(file: AIModelReferenceFile?, session: URLSession? = nil, savedURL: URL? = nil) {
        self.file = file
        self.session = session
        self.savedURL = savedURL
    }

    convenience init(bundle: Bundle, session: URLSession, savedURL: URL) {
        var bundled: AIModelReferenceFile?
        if let url = bundle.url(forResource: "ai-models", withExtension: "json") {
            do {
                bundled = try AIModelReferenceFile.decode(Data(contentsOf: url))
            } catch {
                Self.logger.error("ai-models.json could not be read: \(error.publicLogShape, privacy: .public)")
            }
        } else {
            Self.logger.error("The app bundle has no ai-models.json")
        }
        let saved = (try? Data(contentsOf: savedURL)).flatMap { try? AIModelReferenceFile.decode($0) }
        self.init(file: Self.newer(bundled, saved), session: session, savedURL: savedURL)
    }

    static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        let cache = directory.appendingPathComponent("URLCache", isDirectory: true)
        config.urlCache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 5_000_000, diskPath: cache.path)
        return URLSession(configuration: config)
    }

    // A copy cached before an app update can be older than the one the new build bundles.
    static func newer(_ lhs: AIModelReferenceFile?, _ rhs: AIModelReferenceFile?) -> AIModelReferenceFile? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return rhs.generated > lhs.generated ? rhs : lhs
    }

    var current: AIModelReferenceFile? {
        lock.withLock { file }
    }

    func provider(_ key: String?) -> AIModelReferenceFile.Provider? {
        guard let key else { return nil }
        return current?.providers[key]
    }

    func info(source: AIModelSource, modelID: String) -> AIModelInfo? {
        guard let key = source.key, let model = provider(key)?.model(modelID) else { return nil }
        let info = model.info(providerKey: key)
        return AIModelInfo(
            id: modelID,
            displayName: info.displayName,
            maxOutputTokens: info.maxOutputTokens,
            modalities: info.modalities,
            reasoning: info.reasoning,
            isDeprecated: info.isDeprecated,
            released: info.released
        )
    }

    // At most once an hour, revalidated with the ETag; concurrent callers share one request.
    func refresh(now: Date = Date()) async {
        guard let session else { return }
        let task: Task<Void, Never>? = lock.withLock {
            if let running = refreshTask { return running }
            if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.refreshInterval { return nil }
            lastAttempt = now
            let started = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.load(using: session)
            }
            refreshTask = started
            return started
        }
        guard let task else { return }
        await task.value
        lock.withLock {
            if refreshTask == task { refreshTask = nil }
        }
    }

    private func load(using session: URLSession) async {
        do {
            let (data, response) = try await session.data(from: Self.remoteURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let fetched = try AIModelReferenceFile.decode(data)
            let adopted: Bool = lock.withLock {
                guard file != fetched, Self.newer(file, fetched) == fetched else { return false }
                file = fetched
                return true
            }
            guard adopted, let savedURL else { return }
            try FileManager.default.createDirectory(
                at: savedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: savedURL, options: .atomic)
        } catch {
            Self.logger.debug("The AI model catalog was not refreshed: \(error.publicLogShape, privacy: .public)")
        }
    }
}

enum AIModelMerge {
    // A fine-tune `ft:<base>:...` and a dated snapshot `<base>-YYYY-MM-DD` are described by their base
    // model: the id itself first, then a fine-tune's base as written, then without its date.
    static func lookupKeys(_ id: String) -> [String] {
        var keys = [id]
        var base = id
        if base.hasPrefix("ft:") {
            base = String(base.dropFirst(3).prefix { $0 != ":" })
            keys.append(base)
        }
        if let range = base.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            base.removeSubrange(range)
            keys.append(base)
        }
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    /// `live` is nil when the provider's list could not be read: the catalog's models stand in, marked offline.
    static func merge(
        live: [AIModelInfo]?,
        reference: AIModelReferenceFile.Provider?,
        source: AIModelSource
    ) -> [AIModelInfo] {
        let merged: [AIModelInfo]
        let keepsOrder: Bool
        if let live {
            var seen: Set<String> = []
            merged = live.filter { seen.insert($0.id).inserted }.compactMap { model in
                let entry = reference?.model(model.id)
                guard keeps(entry: entry, source: source) else { return nil }
                return combine(live: model, entry: entry, source: source)
            }
            keepsOrder = source.liveOrdered
        } else {
            guard let reference, let key = source.key else { return [] }
            merged = reference.models
                .filter { keeps(entry: $0, source: source) }
                .map { entry in
                    let info = entry.info(providerKey: key)
                    return AIModelInfo(
                        id: info.id,
                        displayName: info.displayName,
                        maxOutputTokens: info.maxOutputTokens,
                        modalities: info.modalities,
                        reasoning: info.reasoning,
                        isDeprecated: info.isDeprecated,
                        released: info.released,
                        isOffline: true
                    )
                }
            keepsOrder = false
        }
        return arranged(withDefault(merged, reference: reference), keepsOrder: keepsOrder)
    }

    private static func keeps(entry: AIModelReferenceFile.Model?, source: AIModelSource) -> Bool {
        guard let entry else { return !source.hidesUnknown }
        guard let api = source.api, let apis = entry.apis, !apis.isEmpty else { return true }
        return apis.contains(api)
    }

    private static func combine(
        live: AIModelInfo,
        entry: AIModelReferenceFile.Model?,
        source: AIModelSource
    ) -> AIModelInfo {
        guard let entry, let key = source.key else { return live }
        let known = entry.info(providerKey: key)
        let liveName = live.displayName.flatMap { $0.isEmpty ? nil : $0 }
        return AIModelInfo(
            id: live.id,
            displayName: liveName ?? known.displayName,
            contextWindow: live.contextWindow,
            maxOutputTokens: live.maxOutputTokens ?? known.maxOutputTokens,
            modalities: live.modalities.isEmpty ? known.modalities : live.modalities,
            reasoning: live.reasoning ?? known.reasoning,
            isDeprecated: live.isDeprecated || known.isDeprecated,
            retiresAt: live.retiresAt,
            released: live.released ?? known.released,
            isProviderDefault: live.isProviderDefault,
            isOffline: live.isOffline
        )
    }

    private static func withDefault(
        _ models: [AIModelInfo],
        reference: AIModelReferenceFile.Provider?
    ) -> [AIModelInfo] {
        guard !models.contains(where: \.isProviderDefault),
              let defaultID = reference?.defaultModel,
              models.contains(where: { $0.id == defaultID })
        else { return models }
        return models.map { model in
            guard model.id == defaultID else { return model }
            return AIModelInfo(
                id: model.id,
                displayName: model.displayName,
                contextWindow: model.contextWindow,
                maxOutputTokens: model.maxOutputTokens,
                modalities: model.modalities,
                reasoning: model.reasoning,
                isDeprecated: model.isDeprecated,
                retiresAt: model.retiresAt,
                released: model.released,
                isProviderDefault: true,
                isOffline: model.isOffline
            )
        }
    }

    private static func arranged(_ models: [AIModelInfo], keepsOrder: Bool) -> [AIModelInfo] {
        var ordered = models
        if !keepsOrder {
            ordered.sort { lhs, rhs in
                switch (lhs.released, rhs.released) {
                case let (left?, right?) where left != right:
                    return left > right
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                default:
                    return lhs.id < rhs.id
                }
            }
        }
        let defaults = ordered.filter { $0.isProviderDefault && !$0.isDeprecated }
        let active = ordered.filter { !($0.isProviderDefault && !$0.isDeprecated) && !$0.isDeprecated }
        let deprecated = ordered.filter(\.isDeprecated)
        return defaults + active + deprecated
    }
}
