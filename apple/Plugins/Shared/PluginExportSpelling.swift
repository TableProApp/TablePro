import Foundation
import TableProPluginKit

// A server keeps apart names Swift's String equates (NFC and NFD spellings), so an export keys and matches the names
// it groups by their UTF-8 bytes.
nonisolated enum PluginExportSpelling {
    enum Entry<Value> {
        case answered(Value)
        case absent
        // The answer holds the name only in another spelling, so the object is read alone.
        case otherSpelling
    }

    struct ObjectKey: Hashable {
        let group: [UInt8]
        let name: [UInt8]

        init(_ object: PluginExportTable) {
            group = PluginExportSpelling.key(object.databaseName)
            name = PluginExportSpelling.key(object.name)
        }
    }

    static func key(_ name: String) -> [UInt8] {
        Array(name.utf8)
    }

    static func entry<Value>(_ name: String, in answer: [String: Value]) -> Entry<Value> {
        guard let index = answer.index(forKey: name) else { return .absent }
        guard answer[index].key.utf8.elementsEqual(name.utf8) else { return .otherSpelling }
        return .answered(answer[index].value)
    }

    // Objects another object of their group names in a different spelling. A group answer keyed by String holds one
    // entry for both, whichever source wrote it, so each of them is read alone.
    static func twins(among objects: [PluginExportTable]) -> Set<ObjectKey> {
        var spellings: [[UInt8]: [String: Set<[UInt8]>]] = [:]
        for object in objects {
            spellings[key(object.databaseName), default: [:]][object.name, default: []].insert(key(object.name))
        }
        var twins: Set<ObjectKey> = []
        for object in objects {
            let group = key(object.databaseName)
            if let forms = spellings[group]?[object.name], forms.count > 1 {
                twins.insert(ObjectKey(object))
            }
        }
        return twins
    }
}
