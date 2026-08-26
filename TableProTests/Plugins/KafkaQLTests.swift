import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("KafkaQL")
struct KafkaQLTests {
    private func consume(_ input: String) throws -> KafkaConsumeQuery {
        guard case .consume(let query) = try KafkaQL.parse(input) else {
            throw KafkaError.syntax("expected a CONSUME statement")
        }
        return query
    }

    private func produce(_ input: String) throws -> KafkaProduceQuery {
        guard case .produce(let query) = try KafkaQL.parse(input) else {
            throw KafkaError.syntax("expected a PRODUCE statement")
        }
        return query
    }

    @Test("CONSUME defaults to the newest hundred messages")
    func consumeDefaults() throws {
        let query = try consume("CONSUME \"orders\"")
        #expect(query.topic == "orders")
        #expect(query.start == .newest)
        #expect(query.limit == 100)
        #expect(query.skip == 0)
        #expect(query.partitions == nil)
    }

    @Test("Every start mode parses to its own anchor")
    func startModes() throws {
        #expect(try consume("CONSUME t FROM NEWEST").start == .newest)
        #expect(try consume("CONSUME t FROM OLDEST").start == .oldest)
        #expect(try consume("CONSUME t FROM EARLIEST").start == .oldest)
        #expect(try consume("CONSUME t FROM LATEST").start == .newest)
        #expect(try consume("CONSUME t FROM OFFSET 42").start == .offset(42))
        #expect(try consume("CONSUME t FROM TIME 1787709624571").start == .timestamp(1_787_709_624_571))
    }

    @Test("An ISO 8601 instant resolves to milliseconds since the epoch")
    func isoTimestamp() throws {
        let query = try consume("CONSUME t FROM TIME \"2026-01-01T00:00:00Z\"")
        guard case .timestamp(let milliseconds) = query.start else {
            Issue.record("expected a timestamp start")
            return
        }
        #expect(milliseconds == 1_767_225_600_000)
    }

    /// The anchor is what makes paging stable: page two reads the offsets page one resolved
    /// rather than re-deriving "newest" against a tail that has moved on.
    @Test("A resolved anchor round-trips through the statement text")
    func anchorRoundTrip() throws {
        let query = try consume("CONSUME \"orders\" FROM ANCHOR (0:120,1:80,2:0) LIMIT 50")
        #expect(query.start == .resolved([0: 120, 1: 80, 2: 0]))
        #expect(query.limit == 50)
    }

    @Test("LIMIT, SKIP and PARTITION parse together in any order")
    func modifiers() throws {
        let query = try consume("CONSUME \"orders\" PARTITION (0,2) FROM OLDEST LIMIT 25 SKIP 50")
        #expect(query.partitions == [0, 2])
        #expect(query.limit == 25)
        #expect(query.skip == 50)
        #expect(query.start == .oldest)
    }

    @Test("SELECT * FROM is accepted as sugar for CONSUME")
    func selectSugar() throws {
        let query = try consume("SELECT * FROM \"orders\" LIMIT 10")
        #expect(query.topic == "orders")
        #expect(query.limit == 10)
    }

    @Test("A topic name survives every quoting style, and an inner space")
    func quoting() throws {
        #expect(try consume("CONSUME \"my topic\"").topic == "my topic")
        #expect(try consume("CONSUME 'my topic'").topic == "my topic")
        #expect(try consume("CONSUME `my topic`").topic == "my topic")
        #expect(try consume("CONSUME plain").topic == "plain")
    }

    @Test("PRODUCE parses a key, a value, a partition and headers")
    func produceParsing() throws {
        let query = try produce("PRODUCE INTO \"orders\" KEY \"k1\" VALUE \"{}\" PARTITION 2 HEADER \"h\" \"v\"")
        #expect(query.topic == "orders")
        #expect(query.key == "k1")
        #expect(query.value == "{}")
        #expect(query.partition == 2)
        #expect(query.headers.count == 1)
        #expect(query.headers[0].key == "h")
        #expect(query.headers[0].value == Data("v".utf8))
    }

    @Test("PRODUCE with no partition leaves the choice to the partitioner")
    func produceWithoutPartition() throws {
        let query = try produce("PRODUCE INTO orders VALUE \"hello\"")
        #expect(query.partition == nil)
        #expect(query.key == nil)
        #expect(query.value == "hello")
    }

    @Test("SHOW and DESCRIBE parse to their own statements")
    func showAndDescribe() throws {
        #expect(isShowTopics(try KafkaQL.parse("SHOW TOPICS")))
        #expect(isShowGroups(try KafkaQL.parse("SHOW GROUPS")))
        guard case .describeGroup(let group) = try KafkaQL.parse("DESCRIBE GROUP \"order-processor\"") else {
            Issue.record("expected DESCRIBE GROUP")
            return
        }
        #expect(group == "order-processor")
        guard case .describeTopic(let topic) = try KafkaQL.parse("DESCRIBE TOPIC orders") else {
            Issue.record("expected DESCRIBE TOPIC")
            return
        }
        #expect(topic == "orders")
    }

    @Test("A trailing semicolon and surrounding whitespace are tolerated")
    func trailingSemicolon() throws {
        #expect(try consume("  CONSUME \"orders\" LIMIT 5 ;  ").limit == 5)
    }

    /// An unbounded SKIP is not a rude input, it is a crash: a negative one traps in
    /// dropFirst and a huge one overflows the skip+limit addition in the browse engine.
    @Test("SKIP and LIMIT are bounded rather than trusted")
    func skipAndLimitAreBounded() throws {
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("CONSUME t SKIP -1") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("CONSUME t SKIP 9223372036854775807") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("CONSUME t LIMIT 9223372036854775807") }
        #expect(try consume("CONSUME t SKIP 0").skip == 0)
        #expect(try consume("CONSUME t SKIP \(KafkaQL.maximumLimit)").skip == KafkaQL.maximumLimit)
    }

    /// `quote` writes a backslash escape and the tokenizer keeps it so the delimiters can be
    /// found, so `unquote` has to take it back off. Otherwise a produced value carries the
    /// backslashes onto the topic.
    @Test("A quoted value round-trips through quote and unquote")
    func quotingRoundTrips() throws {
        for value in ["plain", "with space", "say \"hi\"", "a,b", "trailing\\"] {
            #expect(KafkaQL.unquote(KafkaQL.quote(value)) == value)
        }
        let produced = try produce("PRODUCE INTO t VALUE \"say \\\"hi\\\"\"")
        #expect(produced.value == "say \"hi\"")
    }

    @Test("Bad input is reported with a message rather than silently ignored")
    func syntaxErrors() {
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("DROP TABLE orders") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("CONSUME") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("CONSUME t LIMIT abc") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("CONSUME t LIMIT 0") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("CONSUME t FROM SIDEWAYS") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("PRODUCE INTO t") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("CONSUME \"unterminated") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("SHOW EVERYTHING") }
    }

    private func isShowTopics(_ statement: KafkaStatement) -> Bool {
        if case .showTopics = statement { return true }
        return false
    }

    private func isShowGroups(_ statement: KafkaStatement) -> Bool {
        if case .showGroups = statement { return true }
        return false
    }
}
