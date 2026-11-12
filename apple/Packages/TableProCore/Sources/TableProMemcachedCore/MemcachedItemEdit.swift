import Foundation

// How an edit of an item the grid read is written. A write that keeps the loaded Value or Flags is a `cas` on the
// unique `gets` returned, so a change made since the read fails instead of being undone.
public enum MemcachedItemEdit: Equatable, Sendable {
    case touch
    case set
    case compareAndSwap(unique: UInt64)
    case needsRefresh

    // Nil when nothing the item stores was edited.
    public static func write(editsValue: Bool, editsFlags: Bool, editsTTL: Bool, unique: UInt64?) -> MemcachedItemEdit? {
        guard editsValue || editsFlags else { return editsTTL ? .touch : nil }
        if editsValue, editsFlags { return .set }
        guard let unique else { return .needsRefresh }
        return .compareAndSwap(unique: unique)
    }
}

// protocol.txt, Storage commands: a `cas` answers `EXISTS` when the item was modified since it was fetched and
// `NOT_FOUND` when it does not exist. Either way nothing was stored.
public enum MemcachedCASRefusal: Equatable, Sendable {
    case changed
    case notFound

    public init?(replyTo command: MemcachedCommand, status: String) {
        guard case .compareAndSwap = command else { return nil }
        switch status {
        case "EXISTS": self = .changed
        case "NOT_FOUND": self = .notFound
        default: return nil
        }
    }
}
