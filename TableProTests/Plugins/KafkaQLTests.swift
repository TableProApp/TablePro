import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

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
        let values = [
            "plain", "with space", "say \"hi\"", "a,b", "trailing\\",
            "C:\\temp\\app.log", "\\\\server\\\\share", "a\\\"b", "\\", "\\\\"
        ]
        for value in values {
            #expect(KafkaQL.unquote(KafkaQL.quote(value)) == value, "round trip of \(value)")
        }
        let produced = try produce("PRODUCE INTO t VALUE \"say \\\"hi\\\"\"")
        #expect(produced.value == "say \"hi\"")
    }

    /// A value carrying a Windows path used to arrive on the topic with its separators gone,
    /// because `quote` escaped the delimiter but not the escape character the tokenizer honours.
    @Test("A value full of backslashes reaches the topic intact")
    func backslashesSurviveTheParser() throws {
        let statement = "PRODUCE INTO \"logs\" VALUE \(KafkaQL.quote("C:\\temp\\app.log"))"
        #expect(try produce(statement).value == "C:\\temp\\app.log")
    }

    /// The same gap let a value close its own quote and have the rest of itself parsed as
    /// further clauses, so a string chose the partition it was written to.
    @Test("A value cannot escape its quotes and inject a clause")
    func aValueCannotInjectAClause() throws {
        let hostile = "a\\\" PARTITION 3 VALUE \"b"
        let query = try produce("PRODUCE INTO \"orders\" VALUE \(KafkaQL.quote(hostile))")
        #expect(query.value == hostile)
        #expect(query.partition == nil)
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
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("DROP") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("DROP TOPIC") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("DROP TOPIC a b") }
    }

    /// Every one of these used to parse. A token the grammar has no use for is a typo or a
    /// modifier the driver does not implement, and reading the statement without it reports
    /// success for something other than what was asked.
    @Test("A token the statement has no use for is refused, not discarded")
    func trailingTokensAreRefused() {
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("SHOW TOPICS INTERNAL") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("SHOW BROKERS ALL") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("SHOW GROUPS STABLE") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("SHOW CLUSTER VERBOSE") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("DESCRIBE TOPIC \"orders\" \"payments\"") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("DESCRIBE GROUP \"a\" \"b\"") }
    }

    /// A partition number that does not parse used to be dropped before anything checked it, so
    /// one typo quietly halved the read and the grid reported a full success.
    @Test("A partition list refuses what it cannot read as a number")
    func partitionListRefusesNonNumbers() throws {
        #expect(try consume("CONSUME t PARTITION (0,2)").partitions == [0, 2])
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("CONSUME t PARTITION (0,two,2)") }
        #expect(throws: KafkaError.self) { _ = try KafkaQL.parse("CONSUME t PARTITION (first)") }
    }

    /// A tail scan pins the end it steps back from, so later pages of a NEWEST browse read the
    /// window page one measured rather than re-deriving it against a moving tail.
    @Test("FROM TAIL parses the exclusive end of each partition")
    func parsesTailAnchors() throws {
        let query = try consume("CONSUME \"orders\" FROM TAIL (0:400,1:250) LIMIT 10 SKIP 10")
        guard case .tail(let ends) = query.start else {
            Issue.record("expected a tail start mode")
            return
        }
        #expect(ends == [0: 400, 1: 250])
        #expect(query.skip == 10)
    }

    /// A topic delete is KafkaQL's own verb. `DROP TABLE` stays a syntax error above, because a
    /// topic is not a table and that text is what the app used to invent for engines with no SQL.
    @Test("DROP TOPIC names the topic to delete")
    func parsesDropTopic() throws {
        guard case .dropTopic(let topic) = try KafkaQL.parse("DROP TOPIC orders") else {
            Issue.record("expected a dropTopic statement")
            return
        }
        #expect(topic == "orders")

        guard case .dropTopic(let quoted) = try KafkaQL.parse("DROP TOPIC \"my topic\"") else {
            Issue.record("expected a dropTopic statement")
            return
        }
        #expect(quoted == "my topic")
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
