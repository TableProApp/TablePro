//
//  AppleIntelligenceTool.swift
//  TablePro
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *)
final class AppleIntelligenceTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    private let spec: ChatToolSpec
    private let onCall: @Sendable (ChatToolSpec, GeneratedContent) async -> String

    init(
        spec: ChatToolSpec,
        schema: GenerationSchema,
        onCall: @escaping @Sendable (ChatToolSpec, GeneratedContent) async -> String
    ) {
        self.spec = spec
        self.name = spec.name
        self.description = spec.description
        self.parameters = schema
        self.onCall = onCall
    }

    func call(arguments: GeneratedContent) async throws -> String {
        await onCall(spec, arguments)
    }
}
#endif
