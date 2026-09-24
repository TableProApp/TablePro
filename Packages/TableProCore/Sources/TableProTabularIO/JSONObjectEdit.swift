import Foundation

public enum JSONMemberChange: Sendable, Equatable {
    case remove
    case update(key: String?, literal: String?)

    public static func rename(to key: String) -> JSONMemberChange {
        .update(key: key, literal: nil)
    }

    public static func replace(with literal: String) -> JSONMemberChange {
        .update(key: nil, literal: literal)
    }

    internal var newKey: String? {
        guard case .update(let key, _) = self else { return nil }
        return key
    }

    internal var newLiteral: String? {
        guard case .update(_, let literal) = self else { return nil }
        return literal
    }

    internal func overridden(by other: JSONMemberChange?) -> JSONMemberChange {
        guard let other else { return self }
        guard self != .remove, other != .remove else { return .remove }
        return .update(key: other.newKey ?? newKey, literal: other.newLiteral ?? newLiteral)
    }
}

public struct JSONMemberEdit: Sendable, Equatable {
    public let sourceKey: String
    public let change: JSONMemberChange

    public init(sourceKey: String, change: JSONMemberChange) {
        self.sourceKey = sourceKey
        self.change = change
    }
}

public struct JSONNewMember: Sendable, Equatable {
    public let key: String
    public let literal: String

    public init(key: String, literal: String) {
        self.key = key
        self.literal = literal
    }
}

public struct JSONObjectEdit: Sendable, Equatable {
    public var edits: [JSONMemberEdit]
    public var appended: [JSONNewMember]

    public init(edits: [JSONMemberEdit] = [], appended: [JSONNewMember] = []) {
        self.edits = edits
        self.appended = appended
    }
}

public enum JSONOutputRow: Sendable, Equatable {
    case source(Int)
    case edited(Int, JSONObjectEdit)
    case new([JSONNewMember])
}

public enum JSONTableWriteError: Error, Equatable, Sendable {
    case duplicateKey(String)
    case invalidLiteral(String)
    case literalSpansLines(String)
    case sourceRowUnavailable(Int)
}
