//
//  AppleIntelligenceSchemaBuilder.swift
//  TablePro
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *)
enum AppleIntelligenceSchemaBuilder {
    static func buildGenerationSchema(from spec: ChatToolSpec) throws -> GenerationSchema {
        let root = dynamicSchema(name: spec.name, description: spec.description, json: spec.inputSchema)
        return try GenerationSchema(root: root, dependencies: [])
    }

    static func generatedContentToJsonValue(_ content: GeneratedContent) throws -> JsonValue {
        guard let data = content.jsonString.data(using: .utf8) else {
            throw AIProviderError.streamingFailed(String(localized: "Could not read tool arguments."))
        }
        return try JSONDecoder().decode(JsonValue.self, from: data)
    }

    private static func dynamicSchema(name: String, description: String?, json: JsonValue) -> DynamicGenerationSchema {
        switch primaryType(of: json) {
        case "object":
            return objectSchema(name: name, description: description, json: json)
        case "array":
            let items = json["items"] ?? .object(["type": .string("string")])
            let element = dynamicSchema(name: "\(name)_item", description: descriptionOf(items), json: items)
            return DynamicGenerationSchema(arrayOf: element, minimumElements: nil, maximumElements: nil)
        case "string":
            let choices = (json["enum"]?.arrayValue ?? []).compactMap(\.stringValue)
            if !choices.isEmpty {
                return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
            }
            return DynamicGenerationSchema(type: String.self, guides: [])
        case "integer":
            return DynamicGenerationSchema(type: Int.self, guides: [])
        case "number":
            return DynamicGenerationSchema(type: Double.self, guides: [])
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self, guides: [])
        default:
            return DynamicGenerationSchema(type: String.self, guides: [])
        }
    }

    private static func objectSchema(name: String, description: String?, json: JsonValue) -> DynamicGenerationSchema {
        let propertySchemas = json["properties"]?.objectValue ?? [:]
        let required = Set((json["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        let properties = propertySchemas.map { key, valueSchema in
            DynamicGenerationSchema.Property(
                name: key,
                description: descriptionOf(valueSchema),
                schema: dynamicSchema(name: "\(name)_\(key)", description: descriptionOf(valueSchema), json: valueSchema),
                isOptional: !required.contains(key)
            )
        }
        return DynamicGenerationSchema(name: name, description: description, properties: properties)
    }

    private static func primaryType(of json: JsonValue) -> String {
        guard let typeValue = json["type"] else { return "object" }
        if let single = typeValue.stringValue { return single }
        if let array = typeValue.arrayValue {
            return array.compactMap(\.stringValue).first(where: { $0 != "null" }) ?? "string"
        }
        return "object"
    }

    private static func descriptionOf(_ json: JsonValue) -> String? {
        json["description"]?.stringValue
    }
}
#endif
