import Foundation

public enum KafkaStartMode: Sendable, Equatable {
    case newest
    case oldest
    case offset(Int64)
    case timestamp(Int64)
    // Per-partition offsets an earlier page resolved, read forward, so page two continues page one exactly.
    case resolved([Int32: Int64])
    // Per-partition exclusive end offsets an earlier page resolved, read backward from the same end.
    case tail([Int32: Int64])
}

public struct KafkaConsumeQuery: Sendable, Equatable {
    public var topic: String
    public var start: KafkaStartMode = .newest
    public var limit: Int = 100
    public var skip: Int = 0
    public var partitions: [Int32]?
}

public struct KafkaRecordHeader: Sendable, Equatable {
    public let key: String
    public let value: Data?

    public init(key: String, value: Data?) {
        self.key = key
        self.value = value
    }
}

public struct KafkaProduceQuery: Sendable, Equatable {
    public var topic: String
    public var partition: Int32?
    public var key: String?
    public var value: String?
    public var headers: [KafkaRecordHeader]
}

public enum KafkaStatement: Sendable, Equatable {
    case consume(KafkaConsumeQuery)
    case produce(KafkaProduceQuery)
    case showTopics
    case showBrokers
    case showGroups
    case describeGroup(String)
    case describeTopic(String)
    case showCluster
    case dropTopic(String)

    public func refusal(readOnly: Bool, allowsDestructive: Bool) -> KafkaStatementRefusal? {
        switch self {
        case .dropTopic:
            if readOnly { return .writeWhileReadOnly("DROP TOPIC") }
            return allowsDestructive ? nil : .destructiveNotApproved("DROP TOPIC")
        case .produce:
            return readOnly ? .writeWhileReadOnly("PRODUCE") : nil
        case .consume, .showTopics, .showBrokers, .showGroups, .describeGroup, .describeTopic, .showCluster:
            return nil
        }
    }
}

public enum KafkaStatementRefusal: Error, Sendable, Equatable {
    case writeWhileReadOnly(String)
    case destructiveNotApproved(String)

    public var message: String {
        switch self {
        case .writeWhileReadOnly(let command):
            return String(format: String(localized: "Refused %@: this statement ran as a read."), command)
        case .destructiveNotApproved(let command):
            return String(format: String(localized: "Refused %@: deleting data was not approved for this statement."), command)
        }
    }
}
