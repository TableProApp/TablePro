import Foundation

public enum QdrantInsertCheck {
    public static let tag = "QDRANT_INSERT_CHECK:"

    public static func encode(collection: String, id: Any, payload: [String: Any], vectors: [String: Any]) -> String? {
        let spec: [String: Any] = ["collection": collection, "id": id, "payload": payload, "vectors": vectors]
        guard let data = try? QdrantJSON.data(spec) else { return nil }
        return tag + data.base64EncodedString()
    }

    public static func decode(_ text: String) -> (collection: String, id: Any, payload: [String: Any], vectors: [String: Any])? {
        guard text.hasPrefix(tag),
              let data = Data(base64Encoded: String(text.dropFirst(tag.count))),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let collection = object["collection"] as? String, let id = object["id"],
              let payload = object["payload"] as? [String: Any]
        else { return nil }
        return (collection, id, payload, object["vectors"] as? [String: Any] ?? [:])
    }
}
