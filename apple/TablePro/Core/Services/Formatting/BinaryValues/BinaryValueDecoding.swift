//
//  BinaryValueDecoding.swift
//  TablePro
//

import Foundation

internal enum BinaryValueFormat: String, Equatable, Sendable {
    case messagePack
    case igbinary
    case protobuf

    var displayName: String {
        switch self {
        case .messagePack: return "MessagePack"
        case .igbinary: return "igbinary"
        case .protobuf: return "Protobuf"
        }
    }
}

internal enum BinaryValueTree: Sendable {
    case json(JSONTreeNode)
    case php(PhpTreeNode)
    case protobuf(ProtobufTreeNode)
}

internal enum BinaryValueDocument: Sendable {
    case decoded(tree: BinaryValueTree, text: String, note: String?)
    case failed(BinaryValueDecodeError)
}

// Pure: the grid calls it per cell on the main actor, the viewer off it.
internal enum BinaryValueDecoding {
    static let maxTextLength = BinaryTextDecoder.maxDisplayBytes
    // The grid stops here too, so a cell never shows a value the viewer then refuses.
    static let maxInputBytes = PhpSerializeParser.sizeCapBytes
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
            case .igbinary:
                text = PhpSerializeWriter.serialize(try IgbinaryDecoder.decode(data, maxValues: budget), limit: limit)
            case .protobuf:
                let fields = try ProtobufWireDecoder.decode(data, maxValues: budget).fields
                text = ProtobufTextWriter.text(fields, multiLine: false, limit: limit)
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
            case .igbinary:
                let value = try IgbinaryDecoder.decode(data)
                return .decoded(
                    tree: .php(PhpTreeBuilder.build(from: value)),
                    text: capped(
                        PhpSerializeWriter.serialize(value, limit: writerLimit(forCap: maxViewerTextLength)),
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
            }
        } catch let error as BinaryValueDecodeError {
            return .failed(error)
        } catch {
            return .failed(BinaryValueDecodeError(kind: .unexpectedEnd, offset: 0))
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
