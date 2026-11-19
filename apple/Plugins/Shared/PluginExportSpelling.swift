import Foundation

// A server keeps apart names Swift's String equates (NFC and NFD spellings), so an export keys and matches the names
// it groups by their UTF-8 bytes.
nonisolated enum PluginExportSpelling {
    enum Entry<Value> {
        case answered(Value)
        case absent
        // The answer holds the name only in another spelling, so the object is read alone.
        case otherSpelling
    }

    static func key(_ name: String) -> [UInt8] {
        Array(name.utf8)
    }

    static func entry<Value>(_ name: String, in answer: [String: Value]) -> Entry<Value> {
        guard let index = answer.index(forKey: name) else { return .absent }
        guard answer[index].key.utf8.elementsEqual(name.utf8) else { return .otherSpelling }
        return .answered(answer[index].value)
    }
}
