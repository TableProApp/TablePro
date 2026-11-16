import Foundation
import TableProTabularIO

// String(data:encoding:) cannot report a partial character. Measured: unmarked UTF-16 decodes big-endian, so the
// byte order is settled once from the first chunk's mark; an odd UTF-16 byte count drops the last byte silently; a
// character split across chunks fails the whole chunk, so its last bytes go back on the front of the next one.
public struct SQLChunkDecoder {
    private let declaredEncoding: String.Encoding
    private var resolvedEncoding: String.Encoding?
    private var unitSize = 1
    private var maximumTrim = 0
    private var pendingTail = Data()

    public var hasPendingBytes: Bool { !pendingTail.isEmpty }

    public init(encoding: String.Encoding) {
        declaredEncoding = encoding
    }

    public mutating func decode(_ rawData: Data) -> String? {
        var data = pendingTail
        data.append(rawData)
        pendingTail.removeAll(keepingCapacity: true)

        let encoding = resolveIfNeeded(startingWith: &data)

        var carried = Data()
        let misalignment = data.count % unitSize
        if misalignment > 0 {
            carried = Data(data.suffix(misalignment))
            data = Data(data.prefix(data.count - misalignment))
        }

        if let decoded = String(data: data, encoding: encoding) {
            pendingTail = carried
            return decoded
        }

        var trim = unitSize
        while trim <= maximumTrim && data.count >= trim {
            let head = Data(data.prefix(data.count - trim))
            if head.isEmpty {
                pendingTail = data + carried
                return ""
            }
            if let decoded = String(data: head, encoding: encoding) {
                pendingTail = Data(data.suffix(trim)) + carried
                return decoded
            }
            trim += unitSize
        }
        return nil
    }

    private mutating func resolveIfNeeded(startingWith data: inout Data) -> String.Encoding {
        if let resolvedEncoding { return resolvedEncoding }

        let resolution = Self.resolve(declaredEncoding, startingWith: data)
        resolvedEncoding = resolution.encoding
        unitSize = resolution.encoding.codeUnitLength
        maximumTrim = Self.maximumTrim(of: resolution.encoding, unitSize: unitSize)
        if resolution.byteOrderMarkLength > 0, data.count >= resolution.byteOrderMarkLength {
            data = Data(data.dropFirst(resolution.byteOrderMarkLength))
        }
        return resolution.encoding
    }

    private struct Resolution {
        let encoding: String.Encoding
        let byteOrderMarkLength: Int
    }

    private static func resolve(_ encoding: String.Encoding, startingWith data: Data) -> Resolution {
        if let mark = ByteOrderMark.leading(data, allowedBy: encoding) {
            return Resolution(encoding: mark.byteOrderedEncoding, byteOrderMarkLength: mark.length)
        }
        return Resolution(encoding: encoding.unmarkedByteOrder, byteOrderMarkLength: 0)
    }

    // CFStringGetMaximumSizeForEncoding counts per UTF-16 unit, so two of them cover one scalar, the most a boundary
    // can cut. An over-report costs a failed decode attempt, never a byte.
    private static func maximumTrim(of encoding: String.Encoding, unitSize: Int) -> Int {
        let cfEncoding = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        guard cfEncoding != kCFStringEncodingInvalidId else { return 0 }
        let perScalar = Int(CFStringGetMaximumSizeForEncoding(2, cfEncoding))
        guard perScalar > unitSize else { return 0 }
        return min(perScalar, 8) - unitSize
    }
}
