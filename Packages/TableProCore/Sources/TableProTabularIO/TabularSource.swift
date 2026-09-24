import Foundation

public enum TabularCellKind: UInt8, Sendable, Equatable {
    case text
    case number
    case boolean
    case null
    case missing
    case object
    case array
    case error
    case date

    public var isNullLike: Bool {
        self == .null || self == .missing
    }
}

public struct TabularCell: Equatable, Sendable {
    public var kind: TabularCellKind
    public var text: String

    public init(kind: TabularCellKind, text: String) {
        self.kind = kind
        self.text = text
    }

    public static func text(_ value: String) -> TabularCell {
        TabularCell(kind: .text, text: value)
    }

    public static let missing = TabularCell(kind: .missing, text: "")
}

public struct TabularCellBuffer {
    private enum Location {
        case external(UnsafeBufferPointer<UInt8>)
        case arena(offset: Int, count: Int)
    }

    private var kinds: [TabularCellKind] = []
    private var locations: [Location] = []
    private var arena: [UInt8] = []
    private var resolved: [UnsafeBufferPointer<UInt8>] = []

    public static let privateSlotSlack = 256
    public static let privateArenaCapacity = 16_384

    public init() {}

    public var count: Int { kinds.count }

    public mutating func reserveThreadPrivateCapacity(slots: Int) {
        let capacity = max(slots, 0) + Self.privateSlotSlack
        kinds.reserveCapacity(capacity)
        locations.reserveCapacity(capacity)
        resolved.reserveCapacity(capacity)
        arena.reserveCapacity(Self.privateArenaCapacity)
    }

    public mutating func reset(slots: Int, fill kind: TabularCellKind) {
        arena.removeAll(keepingCapacity: true)
        kinds.removeAll(keepingCapacity: true)
        locations.removeAll(keepingCapacity: true)
        kinds.append(contentsOf: repeatElement(kind, count: slots))
        locations.append(contentsOf: repeatElement(Location.arena(offset: 0, count: 0), count: slots))
    }

    public mutating func setExternal(_ slot: Int, _ bytes: UnsafeBufferPointer<UInt8>, kind: TabularCellKind) {
        kinds[slot] = kind
        locations[slot] = .external(bytes)
    }

    public mutating func setCopy(_ slot: Int, _ bytes: UnsafeBufferPointer<UInt8>, kind: TabularCellKind) {
        kinds[slot] = kind
        locations[slot] = .arena(offset: arena.count, count: bytes.count)
        arena.append(contentsOf: bytes)
    }

    public mutating func setUTF8(_ slot: Int, _ string: String, kind: TabularCellKind) {
        kinds[slot] = kind
        let start = arena.count
        arena.append(contentsOf: string.utf8)
        locations[slot] = .arena(offset: start, count: arena.count - start)
    }

    public mutating func setTranscoded(
        _ slot: Int,
        _ bytes: UnsafeBufferPointer<UInt8>,
        from encoding: TabularTextEncoding,
        kind: TabularCellKind
    ) {
        guard encoding != .utf8, !TabularTextCodec.isASCII(bytes) else {
            setCopy(slot, bytes, kind: kind)
            return
        }
        kinds[slot] = kind
        let start = arena.count
        TabularTextCodec.appendUTF8(of: bytes, from: encoding, into: &arena)
        locations[slot] = .arena(offset: start, count: arena.count - start)
    }

    public mutating func setEmpty(_ slot: Int, kind: TabularCellKind) {
        kinds[slot] = kind
        locations[slot] = .arena(offset: 0, count: 0)
    }

    public mutating func withResolved<R>(_ body: (TabularRowCells) -> R) -> R {
        arena.withUnsafeBufferPointer { arenaBuffer in
            resolved.removeAll(keepingCapacity: true)
            for location in locations {
                switch location {
                case .external(let bytes):
                    resolved.append(bytes)
                case .arena(let offset, let count):
                    guard count > 0, let base = arenaBuffer.baseAddress else {
                        resolved.append(UnsafeBufferPointer(start: nil, count: 0))
                        continue
                    }
                    resolved.append(UnsafeBufferPointer(start: base + offset, count: count))
                }
            }
            return body(TabularRowCells(kinds: kinds, bytes: resolved))
        }
    }
}

public struct TabularRowCells {
    public let kinds: [TabularCellKind]
    public let bytes: [UnsafeBufferPointer<UInt8>]

    public var count: Int { kinds.count }

    public func string(at index: Int) -> String {
        TabularTextCodec.utf8String(bytes[index])
    }
}

public protocol TabularSource: Sendable {
    var rowCount: Int { get }
    var columnCount: Int { get }
    var intrinsicColumnNames: [String]? { get }
    var absentCell: TabularCell { get }

    func cell(row: Int, column: Int) -> TabularCell
    func cells(row: Int) -> [TabularCell]

    func scan<Rows: Collection>(
        columns: [Int],
        rows: Rows,
        _ body: (Int, TabularRowCells) -> Bool
    ) where Rows.Element == Int
}
