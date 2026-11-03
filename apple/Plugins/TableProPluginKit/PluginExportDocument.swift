import Foundation

/// A field's stored value and its display cell travel together so masking can replace the former.
public struct PluginExportField: Codable, Equatable, Sendable {
    public let name: String
    public let canonicalJSON: String
    public let typeName: String
    public let cellValue: PluginCellValue

    public init(name: String, canonicalJSON: String, typeName: String, cellValue: PluginCellValue) {
        self.name = name
        self.canonicalJSON = canonicalJSON
        self.typeName = typeName
        self.cellValue = cellValue
    }
}

/// Field order and stored nulls are part of a document, even when its grid has sampled columns.
public struct PluginExportDocument: Codable, Equatable, Sendable {
    public let fields: [PluginExportField]

    /// The driver measures stored BSON bytes; masking can grow the value, so exporters need a bound
    /// that callers increase when replacing fields. Nil means batch sizing must treat this document alone.
    public let bsonSizeUpperBound: Int?

    public init(fields: [PluginExportField], bsonSizeUpperBound: Int? = nil) {
        self.fields = fields
        self.bsonSizeUpperBound = bsonSizeUpperBound
    }

    public var canonicalJSON: String {
        let members = fields.map { field in
            let key = PluginExportDocument.jsonString(field.name)
            return key + ":" + field.canonicalJSON
        }
        return "{" + members.joined(separator: ",") + "}"
    }

    public static func jsonString(_ value: String) -> String {
        var encoded = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: encoded += "\\\""
            case 0x5C: encoded += "\\\\"
            case 0...0x1F: encoded += String(format: "\\u%04x", scalar.value)
            default: encoded.unicodeScalars.append(scalar)
            }
        }
        return encoded + "\""
    }
}

public enum PluginExportStreamElement: Sendable {
    case header(PluginStreamHeader)
    case rows([PluginRow], documents: [PluginExportDocument]?)

    public static func wrapping(
        _ stream: AsyncThrowingStream<PluginStreamElement, Error>
    ) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await element in stream {
                        switch element {
                        case .header(let header): continuation.yield(.header(header))
                        case .rows(let rows): continuation.yield(.rows(rows, documents: nil))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func cells(
        _ stream: AsyncThrowingStream<PluginExportStreamElement, Error>
    ) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var columns: Set<Data>?
                var columnCount = 0
                do {
                    for try await element in stream {
                        switch element {
                        case .header(let header):
                            columns = Set(header.columns.map { Data($0.utf8) })
                            columnCount = header.columns.count
                            continuation.yield(.header(header))
                        case .rows(let rows, let documents):
                            if let documents {
                                guard let columns, documents.count == rows.count,
                                      rows.allSatisfy({ $0.count == columnCount }) else {
                                    throw PluginExportError.exportFailed(String(localized: "Export documents do not match their columns and rows", bundle: .main))
                                }
                                // Fixed columns cannot carry a field the cursor first returned after its sample.
                                guard documents.allSatisfy({ document in
                                    document.fields.allSatisfy { columns.contains(Data($0.name.utf8)) }
                                }) else {
                                    throw PluginExportError.exportFailed(String(localized: "The column stream cannot represent every document field", bundle: .main))
                                }
                            }
                            continuation.yield(.rows(rows))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
