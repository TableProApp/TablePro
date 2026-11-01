//
//  BinaryValueDecoding.swift
//  TablePro
//

import Foundation

internal enum BinaryValueFormat: Hashable, Sendable {
    case messagePack
    case protobuf
    case igbinary
    case avro(schemaID: String)
    case protobufSchema(schemaID: String, message: String)
    case schemaRegistry(connectionID: UUID)

    var displayName: String {
        switch self {
        case .messagePack: return "MessagePack"
        case .protobuf, .protobufSchema: return "Protobuf"
        case .igbinary: return "igbinary"
        case .avro: return "Avro"
        case .schemaRegistry: return "Schema Registry"
        }
    }
}

internal enum BinaryValueTree: Sendable {
    case json(JSONTreeNode)
    case protobuf(ProtobufTreeNode)
    case php(PhpTreeNode)
}

internal enum BinaryValueDocument: Sendable {
    case decoded(tree: BinaryValueTree, text: String, note: String?)
    case failed(BinaryValueDecodeError)
    // Nothing to judge the bytes by: the format names a schema this Mac no longer has.
    case missingSchema
    case registryUnavailable(schemaID: UInt32, reason: String)
}

// The Confluent wire format: magic byte 0, then the schema ID, big-endian.
internal enum SchemaRegistryFrame {
    static let headerLength = 5

    static func schemaID(_ data: Data) throws -> UInt32 {
        guard data.count >= headerLength, data.first == 0 else {
            throw BinaryValueDecodeError(kind: .notFramed, offset: 0)
        }
        var reader = BinaryValueReader(data)
        try reader.skip(1)
        return try reader.readUInt32()
    }

    static func jsonText(_ data: Data) throws -> String {
        guard let text = String(data: data.dropFirst(headerLength), encoding: .utf8) else {
            throw BinaryValueDecodeError(kind: .invalidField, offset: headerLength)
        }
        return text
    }
}

// Pure but for the schema caches: the grid calls it per cell on the main actor, the viewer off it.
internal enum BinaryValueDecoding {
    static let maxTextLength = BinaryTextDecoder.maxDisplayBytes
    // The grid stops here too, so a cell never shows a value the viewer then refuses.
    static let maxInputBytes = 5_000_000
    static let maxViewerTextLength = 500_000

    // Budgeted to what the cell can show, so a fault past that point is the viewer's to report.
    static func text(_ data: Data, format: BinaryValueFormat) -> String? {
        guard data.count <= maxInputBytes else { return nil }
        let budget = maxTextLength + 1
        let limit = writerLimit(forCap: maxTextLength)
        let text: String
        do {
            switch format {
            case .messagePack:
                let value = try MessagePackDecoder.decode(data, maxValues: budget)
                text = MessagePackTextWriter.json(value, pretty: false, limit: limit)
            case .protobuf:
                let fields = try ProtobufWireDecoder.decode(data, maxValues: budget).fields
                text = ProtobufTextWriter.text(fields, multiLine: false, limit: limit)
            case .igbinary:
                text = PhpSerializeWriter.text(try IgbinaryDecoder.decode(data, maxValues: budget), limit: limit)
            case .avro(let schemaID):
                guard let schema = AvroSchemaStore.shared.schema(id: schemaID) else { return nil }
                let value = try AvroDecoder.decode(
                    data, schema: schema, maxValues: budget, maxValuesRead: AvroDecoder.maxValuesReadInCell
                ).value
                text = MessagePackTextWriter.json(value, pretty: false, limit: limit)
            case .protobufSchema(let schemaID, let message):
                guard let schema = ProtobufSchemaStore.shared.schema(id: schemaID) else { return nil }
                let decoded = try ProtobufSchemaDecoder.decode(data, schema: schema, message: message, maxValues: budget)
                text = ProtobufSchemaTextWriter.text(decoded.fields, multiLine: false, limit: limit)
            case .schemaRegistry(let connectionID):
                let schemaID = try SchemaRegistryFrame.schemaID(data)
                guard case .success(let schema)? = SchemaRegistryCache.shared.cachedSchema(
                    connectionID: connectionID, schemaID: schemaID
                ) else { return nil }
                text = try registryText(data, schema: schema, maxValues: budget, limit: limit)
            }
        } catch {
            return nil
        }
        return capped(text, at: maxTextLength)
    }

    // Writers count UTF-8 bytes and the cap counts UTF-16 units. Three bytes per unit at most, so text
    // a writer cut short is always past the cap, and always gets the marker.
    private static func writerLimit(forCap cap: Int) -> Int {
        cap * 3 + 3
    }

    private static func capped(_ text: String, at limit: Int) -> String {
        guard (text as NSString).length > limit else { return text }
        return TreeDisplayText.cut(text, limit: limit).text + BinaryTextDecoder.truncationMarker
    }

    static func document(_ data: Data, format: BinaryValueFormat) -> BinaryValueDocument {
        guard data.count <= maxInputBytes else {
            return .failed(BinaryValueDecodeError(kind: .tooLarge, offset: 0))
        }
        do {
            switch format {
            case .messagePack:
                let value = try MessagePackDecoder.decode(data)
                return .decoded(
                    tree: .json(MessagePackTreeBuilder.build(from: value)),
                    text: capped(
                        MessagePackTextWriter.json(value, pretty: true, limit: writerLimit(forCap: maxViewerTextLength)),
                        at: maxViewerTextLength
                    ),
                    note: nil
                )
            case .protobuf:
                let message = try ProtobufWireDecoder.decode(data)
                return .decoded(
                    tree: .protobuf(ProtobufTreeBuilder.build(from: message.fields)),
                    text: capped(
                        ProtobufTextWriter.text(message.fields, multiLine: true, limit: writerLimit(forCap: maxViewerTextLength)),
                        at: maxViewerTextLength
                    ),
                    note: message.framing.map(framingNote)
                )
            case .igbinary:
                let value = try IgbinaryDecoder.decode(data)
                return .decoded(
                    tree: .php(PhpTreeBuilder.build(from: value)),
                    text: capped(
                        PhpSerializeWriter.text(value, limit: writerLimit(forCap: maxViewerTextLength)),
                        at: maxViewerTextLength
                    ),
                    note: nil
                )
            case .avro(let schemaID):
                guard let schema = AvroSchemaStore.shared.schema(id: schemaID) else { return .missingSchema }
                let message = try AvroDecoder.decode(data, schema: schema)
                return .decoded(
                    tree: .json(MessagePackTreeBuilder.build(from: message.value)),
                    text: capped(
                        MessagePackTextWriter.json(message.value, pretty: true, limit: writerLimit(forCap: maxViewerTextLength)),
                        at: maxViewerTextLength
                    ),
                    note: message.framing.map(framingNote)
                )
            case .protobufSchema(let schemaID, let message):
                guard let schema = ProtobufSchemaStore.shared.schema(id: schemaID) else { return .missingSchema }
                return protobufDocument(try ProtobufSchemaDecoder.decode(data, schema: schema, message: message))
            case .schemaRegistry(let connectionID):
                let schemaID = try SchemaRegistryFrame.schemaID(data)
                switch SchemaRegistryCache.shared.cachedSchema(connectionID: connectionID, schemaID: schemaID) {
                case .success(let schema)?:
                    return try registryDocument(data, schema: schema)
                case .failure(let error)?:
                    return .registryUnavailable(schemaID: schemaID, reason: error.reason)
                case nil:
                    return .registryUnavailable(
                        schemaID: schemaID, reason: String(localized: "The schema is still being fetched.")
                    )
                }
            }
        } catch let error as BinaryValueDecodeError {
            return .failed(error)
        } catch {
            return .failed(BinaryValueDecodeError(kind: .unexpectedEnd, offset: 0))
        }
    }

    static func registryText(_ data: Data, schema: RegistrySchema, maxValues: Int, limit: Int) throws -> String {
        switch schema {
        case .avro(let avro):
            let value = try AvroDecoder.decodeRegistryPayload(
                data.dropFirst(SchemaRegistryFrame.headerLength), schema: avro,
                maxValues: maxValues, maxValuesRead: AvroDecoder.maxValuesReadInCell
            )
            return MessagePackTextWriter.json(value, pretty: false, limit: limit)
        case .protobuf(let protobuf):
            let message = try ProtobufSchemaDecoder.decode(data, schema: protobuf, message: nil, maxValues: maxValues)
            return ProtobufSchemaTextWriter.text(message.fields, multiLine: false, limit: limit)
        case .json:
            return try SchemaRegistryFrame.jsonText(data)
        }
    }

    static func registryDocument(_ data: Data, schema: RegistrySchema) throws -> BinaryValueDocument {
        switch schema {
        case .avro(let avro):
            let schemaID = try SchemaRegistryFrame.schemaID(data)
            let value = try AvroDecoder.decodeRegistryPayload(data.dropFirst(SchemaRegistryFrame.headerLength), schema: avro)
            return .decoded(
                tree: .json(MessagePackTreeBuilder.build(from: value)),
                text: capped(
                    MessagePackTextWriter.json(value, pretty: true, limit: writerLimit(forCap: maxViewerTextLength)),
                    at: maxViewerTextLength
                ),
                note: framingNote(.confluent(schemaID: schemaID))
            )
        case .protobuf(let protobuf):
            return protobufDocument(try ProtobufSchemaDecoder.decode(data, schema: protobuf, message: nil))
        case .json:
            let text = try SchemaRegistryFrame.jsonText(data)
            guard case .success(let tree) = JSONTreeParser.parse(text) else {
                throw BinaryValueDecodeError(kind: .invalidField, offset: SchemaRegistryFrame.headerLength)
            }
            return .decoded(
                tree: .json(tree),
                text: capped(text, at: maxViewerTextLength),
                note: framingNote(.confluent(schemaID: try SchemaRegistryFrame.schemaID(data)))
            )
        }
    }

    private static func protobufDocument(_ message: ProtobufTypedMessage) -> BinaryValueDocument {
        .decoded(
            tree: .protobuf(ProtobufSchemaTreeBuilder.build(from: message)),
            text: capped(
                ProtobufSchemaTextWriter.text(message.fields, multiLine: true, limit: writerLimit(forCap: maxViewerTextLength)),
                at: maxViewerTextLength
            ),
            note: message.framing.map(framingNote)
        )
    }

    private static func framingNote(_ framing: AvroFraming) -> String {
        switch framing {
        case .confluent(let schemaID):
            return String(format: String(localized: "Schema Registry framing: schema ID %lld"), Int(schemaID))
        case .singleObject(let fingerprint):
            return String(
                format: String(localized: "Avro single-object encoding: schema fingerprint %@"),
                String(format: "%016llX", fingerprint)
            )
        }
    }

    private static func framingNote(_ framing: ProtobufFraming) -> String {
        let indexes = framing.messageIndexes.map(String.init).joined(separator: ", ")
        return String(
            format: String(localized: "Schema Registry framing: schema ID %lld, message index %@"),
            Int(framing.schemaID),
            indexes
        )
    }
}
