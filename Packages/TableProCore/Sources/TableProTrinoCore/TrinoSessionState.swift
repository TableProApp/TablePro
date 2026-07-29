import Foundation

public final class TrinoSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var _catalog: String?
    private var _schema: String?
    private var _sessionProperties: [String: String]
    private var _preparedStatements: [String: String]
    private var _transactionId: String?

    public init(
        catalog: String? = nil,
        schema: String? = nil,
        sessionProperties: [String: String] = [:],
        preparedStatements: [String: String] = [:],
        transactionId: String? = nil
    ) {
        self._catalog = catalog
        self._schema = schema
        self._sessionProperties = sessionProperties
        self._preparedStatements = preparedStatements
        self._transactionId = transactionId
    }

    public var catalog: String? { lock.withLock { _catalog } }
    public var schema: String? { lock.withLock { _schema } }
    public var transactionId: String? { lock.withLock { _transactionId } }
    public var sessionProperties: [String: String] { lock.withLock { _sessionProperties } }

    public func setCatalog(_ value: String?) {
        lock.withLock { _catalog = value }
    }

    public func setSchema(_ value: String?) {
        lock.withLock { _schema = value }
    }

    public func sessionPropertyHeaderValue() -> String {
        let properties = lock.withLock { _sessionProperties }
        return properties.keys.sorted().compactMap { key in
            guard let value = properties[key] else { return nil }
            return "\(key)=\(Self.encode(value))"
        }.joined(separator: ",")
    }

    public func preparedStatementHeaderValue() -> String {
        let statements = lock.withLock { _preparedStatements }
        return statements.keys.sorted().compactMap { key in
            guard let value = statements[key] else { return nil }
            return "\(key)=\(Self.encode(value))"
        }.joined(separator: ",")
    }

    public func apply(responseHeaders: TrinoHeaderFields, protocolHeaders: TrinoProtocolHeaders) {
        lock.withLock {
            if let catalog = responseHeaders.first(protocolHeaders.setCatalog) {
                _catalog = catalog
            }
            if let schema = responseHeaders.first(protocolHeaders.setSchema) {
                _schema = schema
            }
            for entry in responseHeaders.all(protocolHeaders.setSession) {
                guard let (key, value) = Self.parsePair(entry) else { continue }
                _sessionProperties[key] = Self.decode(value)
            }
            for key in responseHeaders.all(protocolHeaders.clearSession) {
                _sessionProperties.removeValue(forKey: key)
            }
            for entry in responseHeaders.all(protocolHeaders.addedPrepare) {
                guard let (key, value) = Self.parsePair(entry) else { continue }
                _preparedStatements[key] = Self.decode(value)
            }
            for key in responseHeaders.all(protocolHeaders.deallocatedPrepare) {
                _preparedStatements.removeValue(forKey: key)
            }
            if let transactionId = responseHeaders.first(protocolHeaders.startedTransactionId) {
                _transactionId = transactionId
            }
            if responseHeaders.first(protocolHeaders.clearTransactionId) != nil {
                _transactionId = nil
            }
        }
    }

    static func parsePair(_ entry: String) -> (String, String)? {
        guard let separator = entry.firstIndex(of: "=") else { return nil }
        let key = String(entry[..<separator]).trimmingCharacters(in: .whitespaces)
        let value = String(entry[entry.index(after: separator)...])
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    static func decode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}
