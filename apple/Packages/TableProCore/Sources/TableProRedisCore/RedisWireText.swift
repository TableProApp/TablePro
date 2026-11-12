import Foundation

nonisolated public enum RedisWireText {
    // String(data:encoding:) drops a leading byte order mark, which names a different key.
    public static func decode(_ bytes: Data) -> String? {
        let text = String(decoding: bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        return text.utf8.elementsEqual(bytes) ? text : nil
    }
}
