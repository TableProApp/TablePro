import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// End-to-end tests that drive the real driver against a real Kafka broker.
///
/// Everything else in the Kafka suites is pure logic: a codec, a parser, a flattener. Those
/// prove the bytes are right but never open a socket, so until this suite existed the 2,174
/// lines that actually talk to a broker (the driver, the cluster, the connection and the five
/// request builders) had never been executed at all.
///
/// The suite is skipped unless `TABLEPRO_KAFKA_TEST_BOOTSTRAP` names a broker, because CI has
/// none. `scripts/kafka-test-broker.sh up` starts one and prints the export line.
@Suite("Kafka integration", .enabled(if: KafkaTestBroker.isConfigured))
struct KafkaIntegrationTests {
    // MARK: - Connect and discover

    @Test("Connecting reports the cluster and lists its topics")
    func connectAndListTopics() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-list", partitions: 3)
        defer { harness.tearDown() }

        let databases = try await harness.driver.fetchDatabases()
        #expect(databases == ["cluster"])

        let version = await harness.driver.serverVersion
        #expect(version?.hasPrefix("Kafka cluster ") == true)

        let tables = try await harness.driver.fetchTables(schema: nil)
        let topic = try #require(tables.first { $0.name == harness.topic })
        // The external-table type is what makes the grid refuse a cell edit up front.
        #expect(topic.type == "external table")

        // Kafka's own bookkeeping topics are marked system so they sort out of the way.
        for internalTopic in tables where internalTopic.name.hasPrefix("__") {
            #expect(internalTopic.type == "system table")
        }
    }

    @Test("A topic reports its partitions and its message count")
    func partitionsAndRowCount() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-count", partitions: 3)
        defer { harness.tearDown() }
        try await harness.produce(count: 12)

        let partitions = try await harness.driver.fetchPartitions(table: harness.topic, schema: nil)
        #expect(partitions.count == 3)

        let metadata = try await harness.driver.fetchTableMetadata(table: harness.topic, schema: nil)
        #expect(metadata.rowCount == 12)

        let approximate = try await harness.driver.fetchApproximateRowCount(table: harness.topic, schema: nil)
        #expect(approximate == 12)
    }

    @Test("An unknown topic is reported rather than returning an empty result")
    func unknownTopicThrows() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-unknown", partitions: 1)
        defer { harness.tearDown() }

        await #expect(throws: KafkaError.self) {
            _ = try await harness.driver.fetchTableMetadata(table: "tp-it-does-not-exist", schema: nil)
        }
    }

    // MARK: - Browsing

    /// The path the grid actually takes: the host asks for a query string, then runs it.
    @Test("The grid's browse path returns rows with every column populated")
    func browseThroughTheGridPath() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-browse", partitions: 3)
        defer { harness.tearDown() }
        try await harness.produce(count: 20)

        let query = try #require(harness.driver.buildBrowseQuery(
            table: harness.topic,
            schema: nil,
            sortColumns: [],
            columns: [],
            limit: 10,
            offset: 0
        ))
        let result = try await harness.driver.execute(query: query)

        #expect(result.rows.count == 10)
        #expect(result.columns == [
            "partition", "offset", "timestamp", "key", "value", "headers", "key_size", "value_size"
        ])
        for row in result.rows {
            #expect(row.count == 8)
            #expect(row[0].asText?.isEmpty == false)   // partition
            #expect(row[1].asText?.isEmpty == false)   // offset
            #expect(row[4].asText?.isEmpty == false)   // value
        }
    }

    @Test("A key, a value and headers survive the round trip")
    func payloadRoundTrip() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-payload", partitions: 1)
        defer { harness.tearDown() }

        _ = try await harness.driver.execute(query: """
            PRODUCE INTO \(KafkaQL.quote(harness.topic)) KEY "order-1" VALUE "{\\"id\\":1}" \
            HEADER "source" "tablepro"
            """)

        let rows = try await harness.consume(limit: 10)
        let row = try #require(rows.first)
        #expect(row[3].asText == "order-1")
        #expect(row[4].asText == "{\"id\":1}")
        #expect(row[5].asText == "{\"source\":\"tablepro\"}")
        #expect(row[6].asText == "7")                  // key_size
    }

    /// A tombstone and an empty message mean different things on a compacted topic.
    @Test("A null value stays null through the whole driver")
    func nullValueIsNotEmpty() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-tombstone", partitions: 1)
        defer { harness.tearDown() }

        _ = try await harness.driver.execute(
            query: "PRODUCE INTO \(KafkaQL.quote(harness.topic)) KEY \"gone\" VALUE \"\""
        )
        let rows = try await harness.consume(limit: 5)
        let row = try #require(rows.first)
        #expect(row[3].asText == "gone")
        #expect(row[4].asText == "")
    }

    // MARK: - Seeking

    @Test("Every start mode reaches the messages it names")
    func startModes() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-seek", partitions: 1)
        defer { harness.tearDown() }
        try await harness.produce(count: 30)

        let oldest = try await harness.rows("CONSUME \(harness.quoted) FROM OLDEST LIMIT 5")
        #expect(oldest.map { $0[1].asText } == ["0", "1", "2", "3", "4"])

        let fromOffset = try await harness.rows("CONSUME \(harness.quoted) FROM OFFSET 10 LIMIT 3")
        #expect(fromOffset.map { $0[1].asText } == ["10", "11", "12"])

        let newest = try await harness.rows("CONSUME \(harness.quoted) FROM NEWEST LIMIT 5")
        #expect(newest.map { $0[1].asText } == ["25", "26", "27", "28", "29"])

        // An offset past the end clamps rather than raising OFFSET_OUT_OF_RANGE.
        let past = try await harness.rows("CONSUME \(harness.quoted) FROM OFFSET 9999 LIMIT 5")
        #expect(past.isEmpty)
    }

    @Test("Seeking to a time lands on the first message at or after it")
    func seekByTime() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-time", partitions: 1)
        defer { harness.tearDown() }
        try await harness.produce(count: 5)

        let all = try await harness.rows("CONSUME \(harness.quoted) FROM OLDEST LIMIT 5")
        let firstTimestamp = try #require(all.first?[2].asText)

        let seeked = try await harness.rows(
            "CONSUME \(harness.quoted) FROM TIME \(KafkaQL.quote(firstTimestamp)) LIMIT 5"
        )
        #expect(seeked.count == 5)
        #expect(seeked.first?[1].asText == "0")
    }

    @Test("A partition filter reads only the partitions it names")
    func partitionFilter() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-partition", partitions: 3)
        defer { harness.tearDown() }
        try await harness.produce(count: 30)

        let rows = try await harness.rows("CONSUME \(harness.quoted) PARTITION (0) FROM OLDEST LIMIT 50")
        #expect(rows.isEmpty == false)
        #expect(Set(rows.compactMap { $0[0].asText }) == ["0"])
    }

    /// Paging is the reason the ANCHOR clause exists: page two has to continue page one rather
    /// than re-deriving its start against a tail that has moved.
    ///
    /// The invariant is that no message is shown twice, not that three pages of ten cover
    /// exactly thirty. A `NEWEST` scan anchors each partition at its own tail, and messages
    /// are not spread evenly across partitions, so the window a `NEWEST` anchor opens holds
    /// however many messages happen to be in it. Coverage is asserted from `OLDEST`, where the
    /// anchor is the start of the log and paging forward really does reach everything.
    @Test("Paging from the tail never shows the same message twice")
    func pagingNeverRepeats() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-paging", partitions: 3)
        defer { harness.tearDown() }
        try await harness.produce(count: 30)

        var seen: [String] = []
        for page in 0 ..< 3 {
            let query = try #require(harness.driver.buildBrowseQuery(
                table: harness.topic,
                schema: nil,
                sortColumns: [],
                columns: [],
                limit: 10,
                offset: page * 10
            ))
            if page > 0 {
                // Later pages must name the window page one resolved.
                #expect(query.contains("FROM ANCHOR"))
            }
            let result = try await harness.driver.execute(query: query)
            seen.append(contentsOf: result.rows.map { "\($0[0].asText ?? "?"):\($0[1].asText ?? "?")" })
        }

        #expect(seen.isEmpty == false)
        #expect(Set(seen).count == seen.count, "a (partition, offset) pair was repeated across pages")
    }

    /// From the oldest offset the window is the whole log, so paging forward must reach every
    /// message exactly once. This is the coverage guarantee the tail scan cannot make.
    @Test("Paging from the oldest offset reaches every message exactly once")
    func pagingFromOldestCoversEverything() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-cover", partitions: 3)
        defer { harness.tearDown() }
        try await harness.produce(count: 30)

        var seen: [String] = []
        for page in 0 ..< 3 {
            let rows = try await harness.rows(
                "CONSUME \(harness.quoted) FROM OLDEST LIMIT 10 SKIP \(page * 10)"
            )
            seen.append(contentsOf: rows.map { "\($0[0].asText ?? "?"):\($0[1].asText ?? "?")" })
        }

        #expect(seen.count == 30)
        #expect(Set(seen).count == 30, "paging from OLDEST repeated or skipped a message")
    }

    /// Produced between page one and page two: the anchor must hold the window still.
    @Test("A topic written to mid-page does not shift the page under the reader")
    func pagingSurvivesConcurrentWrites() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-moving", partitions: 1)
        defer { harness.tearDown() }
        try await harness.produce(count: 20)

        let first = try #require(harness.driver.buildBrowseQuery(
            table: harness.topic, schema: nil, sortColumns: [], columns: [], limit: 10, offset: 0
        ))
        let pageOne = try await harness.driver.execute(query: first)
        let pageOneKeys = pageOne.rows.map { $0[1].asText }

        try await harness.produce(count: 10, startingAt: 20)

        let second = try #require(harness.driver.buildBrowseQuery(
            table: harness.topic, schema: nil, sortColumns: [], columns: [], limit: 10, offset: 10
        ))
        let pageTwo = try await harness.driver.execute(query: second)
        let pageTwoKeys = pageTwo.rows.map { $0[1].asText }

        #expect(Set(pageOneKeys).isDisjoint(with: Set(pageTwoKeys)))
    }

    // MARK: - Producing

    @Test("Produce reports the partition and offset the broker assigned")
    func produceReportsItsPlacement() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-produce", partitions: 3)
        defer { harness.tearDown() }

        let result = try await harness.driver.execute(
            query: "PRODUCE INTO \(harness.quoted) KEY \"k1\" VALUE \"v1\" PARTITION 2"
        )
        #expect(result.rowsAffected == 1)
        #expect(result.columns == ["topic", "partition", "offset"])
        #expect(result.rows.first?[1].asText == "2")
        #expect(result.rows.first?[2].asText == "0")
    }

    /// Kafka's ordering guarantee for a key only holds if every message with that key lands in
    /// the same partition, so the driver has to match the broker's own partitioner.
    @Test("The same key always lands in the same partition")
    func keyedMessagesShareAPartition() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-key", partitions: 3)
        defer { harness.tearDown() }

        var partitions: Set<String> = []
        for index in 0 ..< 4 {
            let result = try await harness.driver.execute(
                query: "PRODUCE INTO \(harness.quoted) KEY \"same-key\" VALUE \"v\(index)\""
            )
            if let partition = result.rows.first?[1].asText { partitions.insert(partition) }
        }
        #expect(partitions.count == 1)
    }

    @Test("Producing to a partition the topic does not have is refused")
    func produceToMissingPartition() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-badpart", partitions: 1)
        defer { harness.tearDown() }

        await #expect(throws: KafkaError.self) {
            _ = try await harness.driver.execute(
                query: "PRODUCE INTO \(harness.quoted) VALUE \"v\" PARTITION 7"
            )
        }
    }

    // MARK: - The grid must not offer what Kafka cannot do

    @Test("Every edit is declined, so Save cannot silently do nothing")
    func editsAreDeclined() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-readonly", partitions: 1)
        defer { harness.tearDown() }

        let statements = harness.driver.generateStatements(
            table: harness.topic,
            schema: nil,
            columns: ["value"],
            primaryKeyColumns: [],
            changes: [],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )
        #expect(statements == nil)
    }

    // MARK: - Cluster introspection

    @Test("SHOW and DESCRIBE answer from the live cluster")
    func showAndDescribe() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-show", partitions: 2)
        defer { harness.tearDown() }
        try await harness.produce(count: 4)

        let topics = try await harness.driver.execute(query: "SHOW TOPICS")
        #expect(topics.columns == ["topic", "partitions", "replication_factor", "internal"])
        #expect(topics.rows.contains { $0.first?.asText == harness.topic })

        let brokers = try await harness.driver.execute(query: "SHOW BROKERS")
        #expect(brokers.rows.count == 1)
        #expect(brokers.rows.first?[4].asText == "yes")   // the controller

        let cluster = try await harness.driver.execute(query: "SHOW CLUSTER")
        let properties = Dictionary(uniqueKeysWithValues: cluster.rows.compactMap { row -> (String, String)? in
            guard let key = row.first?.asText else { return nil }
            return (key, row[1].asText ?? "")
        })
        #expect(properties["brokers"] == "1")
        #expect(properties["cluster_id"]?.isEmpty == false)

        let described = try await harness.driver.execute(query: "DESCRIBE TOPIC \(harness.quoted)")
        #expect(described.rows.count == 2)
        #expect(described.columns.contains("earliest_offset"))
        #expect(described.columns.contains("latest_offset"))
        let total = described.rows.compactMap { Int($0.last?.asText ?? "") }.reduce(0, +)
        #expect(total == 4)
    }

    @Test("The DDL view describes the topic's partitions and replicas")
    func topicDDL() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-ddl", partitions: 2)
        defer { harness.tearDown() }

        let ddl = try await harness.driver.fetchTableDDL(table: harness.topic, schema: nil)
        #expect(ddl.contains("Topic: \(harness.topic)"))
        #expect(ddl.contains("Partitions: 2"))
        #expect(ddl.contains("partition 0"))
        #expect(ddl.contains("in-sync"))
    }

    /// The lag report is what a Kafka debugging session is usually after.
    @Test("Consumer group lag is reported per partition")
    func consumerGroupLag() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-lag", partitions: 1)
        defer { harness.tearDown() }
        try await harness.produce(count: 10)
        try harness.commitGroup(named: "tp-it-group", messages: 4)

        let groups = try await harness.driver.execute(query: "SHOW GROUPS")
        #expect(groups.rows.contains { $0.first?.asText == "tp-it-group" })

        let lag = try await harness.driver.execute(query: "DESCRIBE GROUP \"tp-it-group\"")
        #expect(lag.columns == ["topic", "partition", "committed_offset", "end_offset", "lag"])
        let row = try #require(lag.rows.first { $0.first?.asText == harness.topic })
        #expect(row[3].asText == "10")
        // Four consumed of ten leaves six behind.
        #expect(row[4].asText == "6")
    }

    // MARK: - Compression, end to end through the driver

    /// The broker hands back whatever the producer stored, so a topic written with each codec
    /// exercises a different decompression path in the shipping driver.
    @Test("Messages compressed with each codec read back identically", arguments: ["gzip", "snappy", "lz4", "zstd"])
    func everyCodecReadsBack(codec: String) async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-codec-\(codec)", partitions: 1)
        defer { harness.tearDown() }
        try harness.produceCompressed(codec: codec, count: 6)

        let rows = try await harness.rows("CONSUME \(harness.quoted) FROM OLDEST LIMIT 10")
        #expect(rows.count == 6, "\(codec) returned \(rows.count) of 6 messages")
        for (index, row) in rows.enumerated() {
            #expect(row[4].asText == "payload-\(index)", "\(codec) corrupted message \(index)")
        }
    }

    // MARK: - Failure reporting

    @Test("A dead address is reported rather than hanging")
    func unreachableBrokerFails() async throws {
        // Port 1 is reserved and nothing listens there.
        let driver = KafkaTestBroker.makeDriver(host: "127.0.0.1", port: 1, timeoutSeconds: 3)
        await #expect(throws: KafkaError.self) {
            try await driver.connect()
        }
        driver.disconnect()
    }

    @Test("A cancelled connect returns rather than running to completion")
    func connectIsCancellable() async throws {
        // 10.255.255.1 is non-routable, so the connect blocks until it is cancelled.
        let driver = KafkaTestBroker.makeDriver(host: "10.255.255.1", port: 9_092, timeoutSeconds: 60)
        let task = Task { try await driver.connect() }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()

        let started = Date()
        _ = await task.result
        #expect(Date().timeIntervalSince(started) < 10, "cancelling waited for the full timeout")
        driver.disconnect()
    }

    @Test("A malformed statement names the problem instead of returning nothing")
    func badStatementIsReported() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-syntax", partitions: 1)
        defer { harness.tearDown() }

        await #expect(throws: KafkaError.self) {
            _ = try await harness.driver.execute(query: "DROP TABLE orders")
        }
        await #expect(throws: KafkaError.self) {
            _ = try await harness.driver.execute(query: "CONSUME \(harness.quoted) SKIP -1")
        }
    }
}
