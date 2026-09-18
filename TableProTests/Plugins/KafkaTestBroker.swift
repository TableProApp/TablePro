import Foundation
import TableProPluginKit

@testable import TablePro

/// Drives a real Kafka broker for `KafkaIntegrationTests`.
///
/// Topic creation and consumer-group commits go through the broker's own CLI rather than
/// through the driver, so a test that checks the driver's reading is never satisfied by the
/// driver's own writing. `scripts/kafka-test-broker.sh up` starts the broker this expects.
enum KafkaTestBroker {
    /// Overrides for a broker somewhere other than the default.
    ///
    /// These are read only if they arrive, and usually they do not: `xcodebuild` does not pass
    /// the invoking shell's environment through to the test host, so exporting a variable
    /// before `verify.sh test` reaches the runner as nothing. That is why the gate below is a
    /// reachability probe rather than a variable check, which cost one run reporting zero
    /// executed cases while a broker sat there answering.
    static let bootstrapVariable = "TABLEPRO_KAFKA_TEST_BOOTSTRAP"
    static let containerVariable = "TABLEPRO_KAFKA_TEST_CONTAINER"

    static let defaultHost = "127.0.0.1"
    static let defaultPort = 19_092

    /// True when a broker actually answers. Asking the socket rather than the environment is
    /// what makes this work locally and skip on CI, where nothing is listening, without any
    /// plumbing between the two.
    static let isConfigured: Bool = canReachBroker()

    static var endpoint: (host: String, port: Int) {
        guard let raw = ProcessInfo.processInfo.environment[bootstrapVariable],
              case let parts = raw.split(separator: ":"),
              parts.count == 2,
              let port = Int(parts[1]) else {
            return (defaultHost, defaultPort)
        }
        return (String(parts[0]), port)
    }

    static var container: String {
        ProcessInfo.processInfo.environment[containerVariable] ?? "tp-kafka-it"
    }

    /// A plain TCP connect with a short timeout. Enough to know something is listening, and
    /// fast enough that the skip costs nothing on a machine with no broker.
    private static func canReachBroker() -> Bool {
        let (host, port) = endpoint
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { close(socketDescriptor) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socketDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(socketDescriptor, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }

    static func makeDriver(host: String, port: Int, timeoutSeconds: Int = 10) -> KafkaPluginDriver {
        KafkaPluginDriver(config: DriverConnectionConfig(
            host: host,
            port: port,
            username: "",
            password: "",
            database: "",
            ssl: SSLConfiguration(),
            additionalFields: [
                "kafkaSecurityProtocol": "PLAINTEXT",
                "kafkaConnectTimeout": String(timeoutSeconds)
            ]
        ))
    }

    /// A connected driver plus a topic of its own, torn down afterwards.
    ///
    /// Each test gets a uniquely suffixed topic. Sharing one would make the suite
    /// order-dependent and make a failure impossible to attribute.
    static func harness(topic: String, partitions: Int) async throws -> Harness {
        let endpoint = self.endpoint
        let unique = "\(topic)-\(UInt32.random(in: 0 ... UInt32.max))"
        try createTopic(named: unique, partitions: partitions)

        let driver = makeDriver(host: endpoint.host, port: endpoint.port)
        try await driver.connect()
        return Harness(driver: driver, topic: unique)
    }

    struct Harness {
        let driver: KafkaPluginDriver
        let topic: String

        var quoted: String { KafkaQL.quote(topic) }

        func tearDown() {
            driver.disconnect()
            try? KafkaTestBroker.deleteTopic(named: topic)
        }

        /// Produces through the driver, which is also the produce path under test.
        func produce(count: Int, startingAt start: Int = 0) async throws {
            for index in start ..< (start + count) {
                _ = try await driver.execute(
                    query: "PRODUCE INTO \(quoted) KEY \"k\(index)\" VALUE \"payload-\(index)\""
                )
            }
        }

        /// Produces through the broker's CLI with a compression codec, which the driver has no
        /// way to request. Reading these back is the only end-to-end test of decompression.
        func produceCompressed(codec: String, count: Int) throws {
            let lines = (0 ..< count).map { "payload-\($0)" }.joined(separator: "\n")
            try KafkaTestBroker.runCLI(
                "kafka-console-producer.sh",
                ["--topic", topic, "--compression-codec", codec],
                stdin: lines + "\n"
            )
        }

        /// Commits a group offset through the broker's CLI, so the lag the driver reports is
        /// measured against something the driver did not write.
        func commitGroup(named group: String, messages: Int) throws {
            try KafkaTestBroker.runCLI(
                "kafka-console-consumer.sh",
                [
                    "--topic", topic, "--group", group, "--from-beginning",
                    "--max-messages", String(messages), "--timeout-ms", "20000",
                    "--consumer-property", "enable.auto.commit=true",
                    "--consumer-property", "auto.commit.interval.ms=200"
                ]
            )
        }

        func rows(_ query: String) async throws -> [[PluginCellValue]] {
            try await driver.execute(query: query).rows
        }

        func consume(limit: Int) async throws -> [[PluginCellValue]] {
            try await rows("CONSUME \(quoted) FROM OLDEST LIMIT \(limit)")
        }
    }

    // MARK: - Broker CLI

    /// An absolute path, resolved once. The test host does not inherit the shell's PATH, so
    /// spawning a bare `docker` finds nothing and every test fails in milliseconds with an
    /// error the runner does not surface.
    static let dockerPath: String? = {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func createTopic(named topic: String, partitions: Int) throws {
        try runCLI("kafka-topics.sh", [
            "--create", "--topic", topic,
            "--partitions", String(partitions), "--replication-factor", "1"
        ])
    }

    static func deleteTopic(named topic: String) throws {
        try runCLI("kafka-topics.sh", ["--delete", "--topic", topic])
    }

    /// Runs one of the broker's bundled tools inside its container.
    ///
    /// `--bootstrap-server localhost:9092` is the broker's INTERNAL listener, which is what the
    /// CLI must use from inside the container. The external port the driver connects to is a
    /// different listener, and using it here fails with a node-assignment timeout.
    @discardableResult
    static func runCLI(_ tool: String, _ arguments: [String], stdin: String? = nil) throws -> String {
        guard let docker = dockerPath else {
            throw KafkaTestBrokerError.dockerNotFound
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = ["exec"]
            + (stdin == nil ? [] : ["-i"])
            + [container, "/opt/kafka/bin/\(tool)", "--bootstrap-server", "localhost:9092"]
            + arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let input = Pipe()
        if stdin != nil { process.standardInput = input }

        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            input.fileHandleForWriting.closeFile()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw KafkaTestBrokerError.commandFailed(tool: tool, output: text)
        }
        return text
    }
}

enum KafkaTestBrokerError: Error, CustomStringConvertible {
    case commandFailed(tool: String, output: String)
    case dockerNotFound

    var description: String {
        switch self {
        case .dockerNotFound:
            return "docker was not found. The integration suite drives a broker in a container."
        case .commandFailed(let tool, let output):
            return "\(tool) failed:\n\(output)"
        }
    }
}
