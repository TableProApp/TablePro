import Foundation

/// Client-side ObjectId generation, in the layout the MongoDB specification defines: 4 bytes of
/// seconds since the epoch, 5 random bytes fixed per process, then a 3 byte counter.
///
/// Generated here rather than left to the server so an insert can report the `insertedId` the way
/// mongosh does. libmongoc adds the field to the document it sends without writing it back into the
/// caller's, so reading it afterwards reports `null` for every document that did not carry one.
enum MongoScriptObjectId {
    private final class Sequence: @unchecked Sendable {
        private let lock = NSLock()
        private var counter = UInt32.random(in: 0 ... 0xFF_FFFF)

        func next() -> UInt32 {
            lock.lock()
            defer { lock.unlock() }
            counter = (counter &+ 1) & 0xFF_FFFF
            return counter
        }
    }

    private static let processRandom: [UInt8] = (0 ..< 5).map { _ in UInt8.random(in: 0 ... 255) }
    private static let sequence = Sequence()

    static func generate() -> String {
        let seconds = UInt32(Date().timeIntervalSince1970)
        let sequence = Self.sequence.next()

        var bytes: [UInt8] = [
            UInt8((seconds >> 24) & 0xFF), UInt8((seconds >> 16) & 0xFF),
            UInt8((seconds >> 8) & 0xFF), UInt8(seconds & 0xFF)
        ]
        bytes.append(contentsOf: processRandom)
        bytes.append(UInt8((sequence >> 16) & 0xFF))
        bytes.append(UInt8((sequence >> 8) & 0xFF))
        bytes.append(UInt8(sequence & 0xFF))
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func data(fromHex hex: String) -> Data? {
        let characters = Array(hex)
        guard !characters.isEmpty, characters.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let byte = UInt8(String(characters[index ... index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        return Data(bytes)
    }
}
