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

    /// Paging is the reason the TAIL clause exists: page two has to continue page one rather
    /// than re-deriving its start against a tail that has moved.
    ///
    /// The invariant is that no message is shown twice and that no page comes back short, not
    /// that three pages of ten cover exactly thirty. A `NEWEST` scan anchors each partition at
    /// its own tail, and messages are not spread evenly across partitions, so the window it
    /// opens holds however many messages happen to be in it. Coverage is asserted from
    /// `OLDEST`, where the anchor is the start of the log and paging forward really does reach
    /// everything.
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
                // Later pages must name the window page one resolved, and a tail browse pins
                // the END of that window so each page steps further back from it.
                #expect(query.contains("FROM TAIL"))
            }
            let result = try await harness.driver.execute(query: query)
            let rows = result.rows.map { "\($0[0].asText ?? "?"):\($0[1].asText ?? "?")" }
            #expect(rows.count == 10, "page \(page + 1) of a tail browse came back short")
            seen.append(contentsOf: rows)
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

        // Asserted against however many brokers are actually running rather than against one.
        // Pinning the count to 1 is what made these three assertions fail the moment the suite
        // met a cluster big enough to reproduce the routing bug they sit beside.
        let brokers = try await harness.driver.execute(query: "SHOW BROKERS")
        #expect(brokers.columns.last == "takes_admin_requests")
        #expect(brokers.rows.isEmpty == false)
        #expect(brokers.rows.filter { $0[4].asText == "yes" }.count == 1)

        let cluster = try await harness.driver.execute(query: "SHOW CLUSTER")
        let properties = Dictionary(uniqueKeysWithValues: cluster.rows.compactMap { row -> (String, String)? in
            guard let key = row.first?.asText else { return nil }
            return (key, row[1].asText ?? "")
        })
        #expect(properties["brokers"] == String(brokers.rows.count))
        #expect(properties["cluster_id"]?.isEmpty == false)
        #expect(properties["admin_requests_to"]?.isEmpty == false)

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

    // MARK: - Topic deletion

    /// DeleteTopics is hand-written wire protocol, so the only way to trust it is to ask a real
    /// broker. The broker accepts the request and removes the log directories afterwards, so this
    /// waits for the topic to leave the listing rather than asserting it is gone immediately.
    @Test("Dropping a topic removes it from the cluster")
    func dropTopicRemovesIt() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-drop", partitions: 2)
        defer { harness.tearDown() }

        let before = try await harness.driver.fetchTables(schema: nil)
        #expect(before.contains { $0.name == harness.topic })

        let statement = try #require(harness.driver.dropObjectStatement(
            name: harness.topic, objectType: "TABLE", schema: nil, cascade: false
        ))
        #expect(statement == "DROP TOPIC \(harness.quoted)")

        let result = try await harness.driver.execute(query: statement)
        #expect(result.rowsAffected == 1)

        var listed = true
        for _ in 0 ..< 40 where listed {
            try await Task.sleep(nanoseconds: 250_000_000)
            let tables = try await harness.driver.fetchTables(schema: nil)
            listed = tables.contains { $0.name == harness.topic }
        }
        #expect(!listed, "the topic was still listed after the broker accepted the deletion")
    }

    @Test("Dropping a topic that does not exist reports the broker's own answer")
    func dropUnknownTopicReports() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-drop-missing", partitions: 1)
        defer { harness.tearDown() }

        await #expect(throws: (any Error).self) {
            try await harness.driver.execute(query: "DROP TOPIC \"tp-it-no-such-topic-9e3f\"")
        }
    }

    /// The lag report is what a Kafka debugging session is usually after.
    ///
    /// Three partitions rather than one, so the end offsets come from ListOffsets sent to three
    /// different leaders on a multi-broker cluster. With one partition this passed while every
    /// request went to whichever broker the connection happened to hold.
    @Test("Consumer group lag is reported per partition")
    func consumerGroupLag() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-lag", partitions: 3)
        defer { harness.tearDown() }
        // The group consumes everything first, so every partition it was assigned has a
        // committed offset; the six produced afterwards are the lag. Committing only part of a
        // topic leaves the partitions it never reached out of the report entirely, which is
        // correct and not something to assert arithmetic against.
        try await harness.produce(count: 10)
        try harness.commitGroup(named: "tp-it-group", messages: 10)
        try await harness.produce(count: 6, startingAt: 10)

        let groups = try await harness.driver.execute(query: "SHOW GROUPS")
        #expect(groups.rows.contains { $0.first?.asText == "tp-it-group" })

        let lag = try await harness.driver.execute(query: "DESCRIBE GROUP \"tp-it-group\"")
        #expect(lag.columns == ["topic", "partition", "committed_offset", "end_offset", "lag"])
        let rows = lag.rows.filter { $0.first?.asText == harness.topic }
        #expect(rows.count == 3, "every partition the group committed must be reported")
        let written = rows.compactMap { Int($0[3].asText ?? "") }.reduce(0, +)
        let consumed = rows.compactMap { Int($0[2].asText ?? "") }.reduce(0, +)
        let behind = rows.compactMap { Int($0[4].asText ?? "") }.reduce(0, +)
        #expect(written == 16)
        #expect(consumed == 10)
        // Ten consumed of sixteen leaves six behind, wherever the sixteen landed.
        #expect(behind == 6)
    }

    /// A group the cluster has never heard of used to come back as five columns and no rows,
    /// which is byte for byte what a real group with nothing committed returns.
    @Test("Describing a group that does not exist says so")
    func describeUnknownGroupReports() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-nogroup", partitions: 1)
        defer { harness.tearDown() }

        await #expect(throws: (any Error).self) {
            try await harness.driver.execute(query: "DESCRIBE GROUP \"tp-it-no-such-group-4c71\"")
        }
    }

    // MARK: - Routing across brokers

    /// The reported bug (#2993), and the reason the rest of this suite could not catch it.
    ///
    /// A topic's partitions are spread across the cluster's brokers, so every one of these
    /// statements has to reach a broker the connection was not opened to. On a single-broker
    /// cluster they all pass without any routing at all, which is why they are asserted here
    /// against whatever the harness is running and are worth running against three.
    @Test("Every statement that needs an offset works wherever the leaders are")
    func offsetsReachEveryLeader() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-routing", partitions: 6)
        defer { harness.tearDown() }
        try await harness.produce(count: 30)

        let described = try await harness.driver.execute(query: "DESCRIBE TOPIC \(harness.quoted)")
        #expect(described.rows.count == 6)
        let counted = described.rows.compactMap { Int($0.last?.asText ?? "") }.reduce(0, +)
        #expect(counted == 30)

        let metadata = try await harness.driver.fetchTableMetadata(table: harness.topic, schema: nil)
        #expect(metadata.rowCount == 30)

        let consumed = try await harness.rows("CONSUME \(harness.quoted) FROM NEWEST LIMIT 100")
        #expect(consumed.count == 30)
    }

    /// `FROM NEWEST` means the newest messages. On more than one partition the scan steps every
    /// partition back by the page size and reads forward, so the merged run holds several pages
    /// and the newest rows sit at its end; taking the front of it returned the oldest rows of
    /// the tail window and called them the newest.
    @Test("FROM NEWEST returns the newest messages, not the oldest of its window")
    func newestReturnsTheNewest() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-newest", partitions: 3)
        defer { harness.tearDown() }
        try await harness.produce(count: 60)

        let everything = try await harness.rows("CONSUME \(harness.quoted) FROM OLDEST LIMIT 100")
        #expect(everything.count == 60)
        let newestKeys = Set(everything.suffix(10).compactMap { $0[3].asText })

        let newest = try await harness.rows("CONSUME \(harness.quoted) FROM NEWEST LIMIT 10")
        #expect(newest.count == 10)
        #expect(Set(newest.compactMap { $0[3].asText }) == newestKeys)
    }

    /// Page two of a tail browse used to be empty: page one recorded the start of its window
    /// rather than the end, so page two skipped a page inside a window exactly one page long.
    @Test("The second page of a tail browse holds the messages before the first")
    func tailPagingWalksBackwards() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-tailpage", partitions: 3)
        defer { harness.tearDown() }
        try await harness.produce(count: 60)

        var pages: [[String]] = []
        for page in 0 ..< 2 {
            let query = try #require(harness.driver.buildBrowseQuery(
                table: harness.topic,
                schema: nil,
                sortColumns: [],
                columns: [],
                limit: 10,
                offset: page * 10
            ))
            if page > 0 { #expect(query.contains("FROM TAIL")) }
            let rows = try await harness.driver.execute(query: query).rows
            pages.append(rows.compactMap { $0[3].asText })
        }

        #expect(pages[0].count == 10)
        #expect(pages[1].count == 10, "page two of a tail browse must hold the page before it")
        #expect(Set(pages[0]).isDisjoint(with: Set(pages[1])))
    }

    /// A broker answers ListGroups with the groups it coordinates and nothing else, so a client
    /// that asks one broker reports a fraction of them with no error.
    @Test("SHOW GROUPS lists groups from every broker, not just the one connected to")
    func showGroupsCoversEveryBroker() async throws {
        let harness = try await KafkaTestBroker.harness(topic: "tp-it-groups", partitions: 3)
        defer { harness.tearDown() }
        try await harness.produce(count: 6)

        // Several names, because which broker coordinates a group is a hash of its id: one
        // group lands on one broker and says nothing about whether the sweep happened.
        let names = (0 ..< 6).map { "tp-it-sweep-\($0)" }
        for name in names {
            try harness.commitGroup(named: name, messages: 1)
        }

        let listed = try await harness.driver.execute(query: "SHOW GROUPS")
        let found = Set(listed.rows.compactMap { $0.first?.asText })
        for name in names {
            #expect(found.contains(name), "SHOW GROUPS did not list \(name)")
        }

        // And each one is describable, which needs its own coordinator rather than the
        // bootstrap broker.
        for name in names {
            let lag = try await harness.driver.execute(query: "DESCRIBE GROUP \(KafkaQL.quote(name))")
            #expect(lag.rows.isEmpty == false, "DESCRIBE GROUP \(name) returned nothing")
        }
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
