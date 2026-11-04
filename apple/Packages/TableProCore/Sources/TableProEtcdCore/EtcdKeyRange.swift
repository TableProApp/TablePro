import Foundation

public struct EtcdKeyRange: Equatable, Sendable {
    public let key: Data
    public let rangeEnd: Data?

    // clientv3 WithPrefix: an empty prefix reads every key, which etcd takes as "\0" to "\0".
    public init(key: Data, prefix: Bool = false) {
        guard prefix else {
            self.key = key
            rangeEnd = nil
            return
        }
        guard !key.isEmpty else {
            self.key = Self.zeroByte
            rangeEnd = Self.zeroByte
            return
        }
        self.key = key
        rangeEnd = Self.prefixEnd(of: key)
    }

    // clientv3 GetPrefixRangeEnd: the first key past every key that starts with the prefix. A prefix of
    // only 0xFF bytes has none, so the range runs to the end of the keyspace.
    public static func prefixEnd(of prefix: Data) -> Data {
        var bytes = Array(prefix)
        while let last = bytes.last {
            if last < 0xFF {
                bytes[bytes.count - 1] = last + 1
                return Data(bytes)
            }
            bytes.removeLast()
        }
        return zeroByte
    }

    private static let zeroByte = Data([0])
}
