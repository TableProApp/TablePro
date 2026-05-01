import Foundation

public enum JsonRpcCodec {
    public static func encode(_ message: JsonRpcMessage) throws -> Data {
        try message.encode()
    }

    public static func decode(_ data: Data) throws -> JsonRpcMessage {
        try JsonRpcMessage.decode(from: data)
    }

    public static func encodeLine(_ message: JsonRpcMessage) throws -> Data {
        var data = try encode(message)
        data.append(0x0A)
        return data
    }
}
