import Foundation
import TableProKafkaCore
import Testing

struct KafkaQLTests {
    @Test("A comma or U+037E before DROP TOPIC is not skipped", arguments: [
        "\u{37E}DROP TOPIC orders",
        "\u{37E} DROP TOPIC orders",
        ",DROP TOPIC orders",
        ", DROP TOPIC orders",
        " , ,DROP TOPIC orders",
        ",drop topic \"orders\";",
    ])
    func hiddenDropIsNotACommand(text: String) {
        #expect(throws: KafkaQLSyntaxError.self) { try KafkaQL.parse(text) }
    }

    @Test("U+037E inside a statement is part of the word, not a `;`")
    func greekQuestionMarkStaysInTheWord() throws {
        #expect(try KafkaQL.parse("DESCRIBE TOPIC orders\u{37E}") == .describeTopic("orders\u{37E}"))
    }

    @Test("DROP TOPIC still parses, and an ASCII `;` still ends a word", arguments: [
        "DROP TOPIC orders",
        "drop topic \"orders\"",
        "DROP TOPIC `orders`;",
        "DROP TOPIC orders;",
        "DROP\r\nTOPIC orders",
    ])
    func dropTopicParses(text: String) throws {
        #expect(try KafkaQL.parse(text) == .dropTopic("orders"))
    }

    @Test("A `;` ends a word even with no blank after it")
    func semicolonSeparatesWords() {
        #expect(throws: KafkaQLSyntaxError.self) { try KafkaQL.parse("DROP TOPIC a;b") }
    }

    @Test("U+1FEF is part of the word, never a backtick")
    func greekVariaIsNotABacktick() throws {
        #expect(try KafkaQL.parse("DESCRIBE TOPIC \u{1FEF}orders\u{1FEF}") == .describeTopic("\u{1FEF}orders\u{1FEF}"))
        #expect(try KafkaQL.parse("DESCRIBE TOPIC `orders`") == .describeTopic("orders"))
    }

    @Test("A comma after a statement is refused, not dropped")
    func trailingCommaIsRefused() {
        #expect(throws: KafkaQLSyntaxError.self) { try KafkaQL.parse("SHOW TOPICS,") }
        #expect(throws: KafkaQLSyntaxError.self) { try KafkaQL.parse("CONSUME orders, DROP TOPIC orders") }
    }

    @Test("CONSUME and SELECT read their clauses")
    func consumeParses() throws {
        guard case .consume(let partitions) = try KafkaQL.parse("CONSUME orders PARTITION (0, 1) LIMIT 5") else {
            Issue.record("Expected .consume")
            return
        }
        #expect(partitions.topic == "orders")
        #expect(partitions.partitions == [0, 1])
        #expect(partitions.limit == 5)
        #expect(partitions.start == .newest)

        guard case .consume(let tail) = try KafkaQL.parse("CONSUME \"orders\" FROM TAIL (0:400,1:250) LIMIT 100 SKIP 100") else {
            Issue.record("Expected .consume")
            return
        }
        #expect(tail.start == .tail([0: 400, 1: 250]))
        #expect(tail.skip == 100)

        guard case .consume(let select) = try KafkaQL.parse("SELECT * FROM orders FROM OLDEST") else {
            Issue.record("Expected .consume")
            return
        }
        #expect(select.topic == "orders")
        #expect(select.start == .oldest)
    }

    @Test("PRODUCE keeps a comma inside quotes")
    func produceParses() throws {
        guard case .produce(let produce) = try KafkaQL.parse(
            "PRODUCE orders KEY k VALUE \"a,b\" PARTITION 2 HEADER source \"app\""
        ) else {
            Issue.record("Expected .produce")
            return
        }
        #expect(produce.topic == "orders")
        #expect(produce.key == "k")
        #expect(produce.value == "a,b")
        #expect(produce.partition == 2)
        #expect(produce.headers == [KafkaRecordHeader(key: "source", value: Data("app".utf8))])
    }

    @Test("SHOW and DESCRIBE parse", arguments: [
        ("SHOW TOPICS;", KafkaStatement.showTopics),
        ("show brokers", .showBrokers),
        ("SHOW CONSUMERS", .showGroups),
        ("SHOW CLUSTER", .showCluster),
        ("DESCRIBE GROUP payments", .describeGroup("payments")),
        ("DESC TOPIC 'orders'", .describeTopic("orders")),
    ])
    func showAndDescribeParse(text: String, expected: KafkaStatement) throws {
        #expect(try KafkaQL.parse(text) == expected)
    }

    @Test("quote round-trips a value with quotes and backslashes")
    func quoteRoundTrips() throws {
        let topic = "say \\\"hi\\\" \u{37E}, ok"
        #expect(try KafkaQL.parse("DESCRIBE TOPIC \(KafkaQL.quote(topic))") == .describeTopic(topic))
    }

    @Test("A drop needs a destructive approval, and a read-only statement neither drops nor produces")
    func refusals() throws {
        let drop = try KafkaQL.parse("DROP TOPIC orders")
        let produce = try KafkaQL.parse("PRODUCE orders VALUE x")
        let consume = try KafkaQL.parse("CONSUME orders")

        #expect(drop.refusal(readOnly: false, allowsDestructive: true) == nil)
        #expect(drop.refusal(readOnly: false, allowsDestructive: false) == .destructiveNotApproved("DROP TOPIC"))
        #expect(drop.refusal(readOnly: true, allowsDestructive: true) == .writeWhileReadOnly("DROP TOPIC"))

        #expect(produce.refusal(readOnly: false, allowsDestructive: false) == nil)
        #expect(produce.refusal(readOnly: true, allowsDestructive: true) == .writeWhileReadOnly("PRODUCE"))

        #expect(consume.refusal(readOnly: true, allowsDestructive: false) == nil)
        #expect(KafkaStatement.showTopics.refusal(readOnly: true, allowsDestructive: false) == nil)
    }
}
