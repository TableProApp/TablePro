import Foundation

internal actor SpannerParameterTypeCache {
    private static let capacity = 256

    private var entries: [String: [SpannerType]] = [:]
    private var order: [String] = []

    func types(for sql: String) -> [SpannerType]? {
        entries[sql]
    }

    func store(_ types: [SpannerType], for sql: String) {
        if entries.updateValue(types, forKey: sql) == nil {
            order.append(sql)
        }
        guard order.count > Self.capacity else { return }
        let evicted = order.removeFirst()
        entries.removeValue(forKey: evicted)
    }

    func evict(_ sql: String) {
        guard entries.removeValue(forKey: sql) != nil else { return }
        order.removeAll { $0 == sql }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    static func orderedTypes(from fields: [SpannerField], count: Int) throws -> [SpannerType] {
        guard count > 0 else { return [] }
        let byName = Dictionary(fields.map { ($0.name.lowercased(), $0.type) }, uniquingKeysWith: { first, _ in first })
        return try (1...count).map { index in
            guard let type = byName["p\(index)"] else { throw SpannerTransportError.invalidResponse }
            return type
        }
    }
}
