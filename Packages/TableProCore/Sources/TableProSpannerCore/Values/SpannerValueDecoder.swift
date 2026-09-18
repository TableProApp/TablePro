import Foundation

public enum SpannerValueDecoder {
    public static func cell(_ value: SpannerJSONValue, type: SpannerType) -> SpannerCell {
        if case .null = value {
            return .null
        }
        switch type.code {
        case SpannerTypeCode.bytes:
            guard case .string(let encoded) = value, let data = Data(base64Encoded: encoded) else {
                return .text(scalarText(value, type: type))
            }
            return .bytes(data)
        case SpannerTypeCode.array, SpannerTypeCode.structure:
            return .text(SpannerJSONText.typed(value, type: type))
        default:
            return .text(scalarText(value, type: type))
        }
    }

    public static func rows(_ rows: [[SpannerJSONValue]], fields: [SpannerField]) -> [[SpannerCell]] {
        let types = fields.map(\.type)
        return rows.map { row in
            types.indices.map { position in
                position < row.count ? cell(row[position], type: types[position]) : .null
            }
        }
    }

    public static func displayTypeName(_ type: SpannerType) -> String {
        switch type.code {
        case SpannerTypeCode.array:
            return "ARRAY<\(type.arrayElementType.map(displayTypeName) ?? "")>"
        case SpannerTypeCode.structure:
            let members = type.structFields.map { field in
                field.name.isEmpty ? displayTypeName(field.type) : "\(field.name) \(displayTypeName(field.type))"
            }
            return "STRUCT<\(members.joined(separator: ", "))>"
        default:
            return type.typeAnnotation == SpannerTypeCode.pgJSONBAnnotation ? "JSONB" : type.code
        }
    }

    private static func scalarText(_ value: SpannerJSONValue, type: SpannerType) -> String {
        switch value {
        case .string(let text):
            return text
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            return SpannerJSONText.floatText(number, isFloat32: type.code == SpannerTypeCode.float32)
        case .null, .list, .object:
            return SpannerJSONText.generic(value)
        }
    }
}
