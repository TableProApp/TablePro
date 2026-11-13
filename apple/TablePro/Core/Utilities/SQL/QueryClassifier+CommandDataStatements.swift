//
//  QueryClassifier+CommandDataStatements.swift
//  TablePro
//

import Foundation
import TableProMemcachedCore
import TableProRedisCore
import TableProSQLGrammar

extension QueryClassifier {
    // Redis 8.10.3 `COMMAND`: the commands whose second word names the subcommand that runs.
    private static let redisContainerCommands: Set<String> = [
        "ACL", "BACKUP", "CLIENT", "CLUSTER", "COMMAND", "CONFIG", "FT.CONFIG", "FT.CURSOR", "FUNCTION", "HIMPORT",
        "HOTKEYS", "LATENCY", "MEMORY", "MODULE", "OBJECT", "PUBSUB", "SCRIPT", "SLOWLOG", "XGROUP", "XINFO",
        "_FT.CONFIG", "_FT.DEBUG",
    ]

    static func redisDataCommands(_ text: String) -> [DataCommand]? {
        RedisCommandSplitter.commands(in: text).map { redisDataCommand(StatementBlank.trimming($0.text)) }
    }

    // Named past the prefixes the driver unwraps, as `CONTAINER|SUB` for a container. The server folds ASCII only, so
    // a word only Unicode case folding reads as a listed name is one the server does not know.
    private static func redisDataCommand(_ command: String) -> DataCommand {
        guard let arguments = RedisArgumentCodec.split(command) else { return .refused }
        if redisCommandClassification(command).tier == .safe { return .read }
        let decoded = arguments.map { String(bytes: $0, encoding: .utf8) }
        let words = decoded[redisCommandPastPrefixes(decoded.map { $0 ?? "" }).startIndex...]
        guard let first = words.first, let verb = first.map(redisASCIIUppercased) else { return .refused }
        guard redisContainerCommands.contains(verb) else { return .named(verb) }
        guard let second = words.dropFirst().first, let subcommand = second else { return .refused }
        return .named(verb + "|" + redisASCIIUppercased(subcommand))
    }

    private static func redisASCIIUppercased(_ word: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in word.unicodeScalars {
            let isLowercaseLetter = scalar.value >= 0x61 && scalar.value <= 0x7A
            scalars.append(isLowercaseLetter ? Unicode.Scalar(UInt8(scalar.value - 0x20)) : scalar)
        }
        return String(scalars)
    }

    // The driver runs only what its parser reads.
    static func memcachedDataCommands(_ text: String, readings: SQLLexicalReadings) -> [DataCommand]? {
        var commands: [DataCommand] = []
        for statement in readings.all.flatMap({ statements(of: text, grammar: $0) }) {
            guard let command = try? MemcachedCommandParser.parse(statement) else { return nil }
            let isRead = memcachedClassification(statement).tier == .safe
            commands.append(isRead ? .read : .named(memcachedName(of: command)))
        }
        return commands
    }

    private static func memcachedName(of command: MemcachedCommand) -> String {
        switch command {
        case .get(_, let withCAS): return withCAS ? "gets" : "get"
        case .getAndTouch(_, _, let withCAS): return withCAS ? "gats" : "gat"
        case .store(let verb, _, _, _, _): return verb.rawValue
        case .compareAndSwap: return "cas"
        case .touch: return "touch"
        case .delete: return "delete"
        case .increment: return "incr"
        case .decrement: return "decr"
        case .flushAll: return "flush_all"
        case .stats(let arguments): return (["stats"] + arguments).joined(separator: " ")
        case .version: return "version"
        case .metadump: return "lru_crawler metadump"
        }
    }

    static func etcdDataCommands(_ text: String, readings: SQLLexicalReadings) -> [DataCommand]? {
        var commands: [DataCommand] = []
        for statement in readings.all.flatMap({ statements(of: text, grammar: $0) }) {
            guard let operation = try? EtcdCommandParser.parse(statement) else { return nil }
            if etcdClassification(statement).tier == .safe {
                commands.append(.read)
            } else {
                commands.append(etcdName(of: operation).map(DataCommand.named) ?? .refused)
            }
        }
        return commands
    }

    private static func etcdName(of operation: EtcdOperation) -> String? {
        switch operation {
        case .get: return "get"
        case .put: return "put"
        case .create: return "create"
        case .move: return "mv"
        case .del: return "del"
        case .watch: return "watch"
        case .leaseGrant: return "lease grant"
        case .leaseRevoke: return "lease revoke"
        case .leaseTimetolive: return "lease timetolive"
        case .leaseList: return "lease list"
        case .leaseKeepAlive: return "lease keep-alive"
        case .memberList: return "member list"
        case .endpointStatus: return "endpoint status"
        case .endpointHealth: return "endpoint health"
        case .compaction: return "compaction"
        case .authEnable: return "auth enable"
        case .authDisable: return "auth disable"
        case .userAdd: return "user add"
        case .userDelete: return "user delete"
        case .userList: return "user list"
        case .roleAdd: return "role add"
        case .roleDelete: return "role delete"
        case .roleList: return "role list"
        case .userGrantRole: return "user grant-role"
        case .userRevokeRole: return "user revoke-role"
        case .unknown: return nil
        }
    }

    // The whole text, as the driver parses it: `;` is a blank in KafkaQL, so a second statement is a syntax error.
    static func kafkaDataCommands(_ text: String) -> [DataCommand]? {
        guard let statement = try? KafkaQL.parse(text) else { return nil }
        switch statement {
        // Reads by the driver's own rule, `KafkaStatement.refusal`. The SQL tier reads CONSUME as a write.
        case .consume, .showTopics, .showBrokers, .showGroups, .showCluster, .describeGroup, .describeTopic:
            return [.read]
        case .produce(let query):
            return [kafkaNamesServiceTopic(query.topic) ? .refused : .named("PRODUCE")]
        case .dropTopic:
            return [.named("DROP TOPIC")]
        }
    }

    // The broker refuses a produce only into its own `__` topics. Schema Registry keeps its schemas in `_schemas`
    // (`kafkastore.topic`), and Confluent names every internal topic with a leading `_`. Kafka's
    // `ReplicationPolicy.isInternalTopic` (4.4) adds a leading `.` and MirrorMaker 2's `.internal` topics, its Connect
    // stores among them. A Connect worker's stores have no default name; these are the ones Kafka ships in
    // `config/connect-distributed.properties`. Kafka Streams names a store's log and a repartition topic with these
    // suffixes. The broker does not say which topics a worker, a registry or an application uses.
    private static let kafkaConnectTopics: Set<String> = ["connect-configs", "connect-offsets", "connect-status"]

    static func kafkaNamesServiceTopic(_ topic: String) -> Bool {
        if topic.hasPrefix("_") || topic.hasPrefix(".") || kafkaConnectTopics.contains(topic) { return true }
        if topic.hasSuffix("-changelog") || topic.hasSuffix("-repartition") { return true }
        return (topic.hasPrefix("mm2") && topic.hasSuffix(".internal")) || topic.hasSuffix(".checkpoints.internal")
    }
}
