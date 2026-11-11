import Foundation
@testable import TableProPluginKit
import Testing

private struct FakeCNAMEResolver: CNAMEResolving {
    let records: [String: String]
    let failing: Set<String>
    let queried: QueriedNames

    init(_ records: [String: String], failing: Set<String> = [], queried: QueriedNames = QueriedNames()) {
        self.records = records
        self.failing = failing
        self.queried = queried
    }

    func cnameTarget(of name: String, within timeout: Duration?) async -> CNAMELookup {
        queried.append(name)
        if failing.contains(name) {
            return .failed
        }
        return records[name].map(CNAMELookup.found) ?? .notFound
    }
}

private final class QueriedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var names: [String] {
        lock.withLock { storage }
    }

    func append(_ name: String) {
        lock.withLock { storage.append(name) }
    }
}

struct AWSEndpointHostTests {
    @Test("Every AWS-issued RDS form is recognised, with its region")
    func rdsForms() {
        let regions: [String: String?] = [
            "mydb.abc123.us-east-1.rds.amazonaws.com": "us-east-1",
            "mydb.cluster-abc123.eu-west-1.rds.amazonaws.com": "eu-west-1",
            "mydb.cluster-ro-abc123.ap-south-1.rds.amazonaws.com": "ap-south-1",
            "mydb.cluster-custom-abc123.us-west-2.rds.amazonaws.com": "us-west-2",
            "proxy.proxy-abc123.us-east-1.rds.amazonaws.com": "us-east-1",
            "reader.endpoint.proxy-abc123.us-east-1.rds.amazonaws.com": "us-east-1",
            "mydb.abc123.rds.cn-northwest-1.amazonaws.com.cn": "cn-northwest-1",
            "mydb.abc123.cn-north-1.rds.amazonaws.com.cn": "cn-north-1",
            "mydb.abc123.us-gov-west-1.rds.amazonaws.com": "us-gov-west-1",
            "mydb.abc123.rds.us-gov-west-1.amazonaws.com": "us-gov-west-1",
            "mydb.abc123.eusc-de-east-1.rds.amazonaws.eu": "eusc-de-east-1",
            "mydb.abc123.rds.us-iso-east-1.c2s.ic.gov": "us-iso-east-1",
            "mydb.global-abc123.global.rds.amazonaws.com": nil
        ]
        for (host, region) in regions {
            #expect(AWSEndpointHost.isRDSEndpoint(host), "\(host)")
            #expect(AWSEndpointHost.rdsRegion(forHost: host) == region, "\(host)")
        }
    }

    @Test("A name only counts as AWS's when it ends in a partition's suffix")
    func lookalikesAreNotRDS() {
        for host in [
            "mydb.abc123.us-east-1.rds.amazonaws.com.evil.example",
            "mydb.abc123.us-east-1.rds.amazonaws.attacker.com",
            "abc123.us-east-1.rds.amazonaws.com",
            "mydb.abc123.cn-north-1.rds.amazonaws.com",
            "mydb.abc123.us-east-1.rds.amazonaws.com.cn",
            "mydb..us-east-1.rds.amazonaws.com",
            "ec2-54-1-2-3.compute-1.amazonaws.com",
            "a.b.rds.s3.amazonaws.com",
            "a.b.us-east-1.rds.s3.amazonaws.com",
            "mydb.abc123.east.rds.amazonaws.com",
            "my-cluster.abc123.us-east-1.redshift.amazonaws.com",
            "reader.db.example.com",
            "localhost"
        ] {
            #expect(!AWSEndpointHost.isRDSEndpoint(host), "\(host)")
            #expect(AWSEndpointHost.rdsRegion(forHost: host) == nil, "\(host)")
        }
    }

    @Test("Case and one trailing dot do not change the answer")
    func normalization() {
        #expect(AWSEndpointHost.normalized(" MyDB.ABC123.US-EAST-1.RDS.AmazonAWS.com. ") == "mydb.abc123.us-east-1.rds.amazonaws.com")
        #expect(AWSEndpointHost.rdsRegion(forHost: "MyDB.ABC123.US-EAST-1.RDS.AmazonAWS.com.") == "us-east-1")
    }

    @Test("Only literal loopback addresses and names are loopback")
    func loopback() {
        for host in [
            "localhost", "LocalHost", "127.0.0.1", "127.9.8.7", "127.1", "0x7f.1", "2130706433",
            "::1", "0:0:0:0:0:0:0:1", "::ffff:127.0.0.1", "0.0.0.0"
        ] {
            #expect(AWSEndpointHost.isLoopback(host), "\(host)")
        }
        for host in [
            "localhost.localdomain", "localhost.", "127.0.0.1.", "127.0.0.1 ", " localhost", "127.0.0.1.attacker.example",
            "127.evil.example.com", "0177.0.0.1", "0177.12.34.56", "[::1]", "::1%lo0", "::1%x,db.example.com",
            "127.0.0.1,db.example.com",
            "127.0.0.256", "128.0.0.1",
            "::2", "::ffff:10.0.0.1", "db.example.com", ""
        ] {
            #expect(!AWSEndpointHost.isLoopback(host), "\(host)")
        }
    }

    @Test("Literals, loopback, single labels and .local names are never looked up")
    func aliasCandidates() {
        for host in ["reader.db.example.com", "READER.db.example.com."] {
            #expect(AWSEndpointHost.isAliasCandidate(host), "\(host)")
        }
        for host in [
            "", "db", "localhost", "127.0.0.1", "10.0.0.5", "10.1", "0177.12.34.56", "::1", "fe80::1", "printer.local",
            "/tmp/mysql.sock", "a.example.com,b.example.com"
        ] {
            #expect(!AWSEndpointHost.isAliasCandidate(host), "\(host)")
        }
    }

    @Test("A custom name leads to the first RDS endpoint in its chain")
    func walksToFirstRDSName() async {
        let resolver = FakeCNAMEResolver([
            "reader.db.example.com": "mycluster.cluster-ro-abc123.us-east-1.rds.amazonaws.com",
            "mycluster.cluster-ro-abc123.us-east-1.rds.amazonaws.com": "instance-2.abc123.us-east-1.rds.amazonaws.com",
            "instance-2.abc123.us-east-1.rds.amazonaws.com": "ec2-54-1-2-3.compute-1.amazonaws.com"
        ])
        let found = await AWSEndpointHost.rdsEndpoint(behind: "Reader.DB.example.com.", resolver: resolver, within: nil)
        #expect(found == .found("mycluster.cluster-ro-abc123.us-east-1.rds.amazonaws.com"))
    }

    @Test("Hops through names of the user's own before reaching RDS")
    func walksThroughIntermediateNames() async {
        let resolver = FakeCNAMEResolver([
            "db.example.com": "db.internal.example.net",
            "db.internal.example.net": "replica-b.abc123.us-east-1.rds.amazonaws.com"
        ])
        let found = await AWSEndpointHost.rdsEndpoint(behind: "db.example.com", resolver: resolver, within: nil)
        #expect(found == .found("replica-b.abc123.us-east-1.rds.amazonaws.com"))
    }

    @Test("No lookup for a host that already is an RDS endpoint, or cannot have a CNAME")
    func skipsHostsThatNeedNoLookup() async {
        let queried = QueriedNames()
        let resolver = FakeCNAMEResolver([:], queried: queried)
        for host in ["mydb.abc123.us-east-1.rds.amazonaws.com", "127.0.0.1", "10.0.0.5", "localhost", "db"] {
            #expect(await AWSEndpointHost.rdsEndpoint(behind: host, resolver: resolver, within: nil) == .notFound)
        }
        #expect(queried.names.isEmpty)
    }

    @Test("A chain with no RDS endpoint, a loop or too many hops finds nothing")
    func chainsThatFindNothing() async {
        let noRDS = FakeCNAMEResolver(["db.example.com": "ec2-54-1-2-3.compute-1.amazonaws.com"])
        #expect(await AWSEndpointHost.rdsEndpoint(behind: "db.example.com", resolver: noRDS, within: nil) == .notFound)

        let loopQueried = QueriedNames()
        let loop = FakeCNAMEResolver(["a.example.com": "b.example.com", "b.example.com": "a.example.com"], queried: loopQueried)
        #expect(await AWSEndpointHost.rdsEndpoint(behind: "a.example.com", resolver: loop, within: nil) == .notFound)
        #expect(loopQueried.names == ["a.example.com", "b.example.com"])

        var long: [String: String] = [:]
        for hop in 0 ..< 20 {
            long["h\(hop).example.com"] = "h\(hop + 1).example.com"
        }
        long["h20.example.com"] = "mydb.abc123.us-east-1.rds.amazonaws.com"
        let longQueried = QueriedNames()
        let chain = FakeCNAMEResolver(long, queried: longQueried)
        #expect(await AWSEndpointHost.rdsEndpoint(behind: "h0.example.com", resolver: chain, within: nil) == .notFound)
        #expect(longQueried.names.count == 8)
    }

    @Test("A spent time budget stops the walk before it asks")
    func spentBudgetAsksNothing() async {
        let queried = QueriedNames()
        let resolver = FakeCNAMEResolver(["db.example.com": "mydb.abc123.us-east-1.rds.amazonaws.com"], queried: queried)
        #expect(await AWSEndpointHost.rdsEndpoint(behind: "db.example.com", resolver: resolver, within: .zero) == .failed)
        #expect(queried.names.isEmpty)
    }

    @Test("A lookup that fails partway is a failure, not a name with no RDS endpoint")
    func failedHopIsAFailure() async {
        let resolver = FakeCNAMEResolver(["db.example.com": "edge.example.net"], failing: ["edge.example.net"])
        #expect(await AWSEndpointHost.rdsEndpoint(behind: "db.example.com", resolver: resolver, within: nil) == .failed)
    }
}

struct DNSWireNameTests {
    private func decode(_ bytes: [UInt8]) -> String? {
        bytes.withUnsafeBytes { DNSWireName.decode($0) }
    }

    private func wire(_ labels: [String]) -> [UInt8] {
        labels.flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0]
    }

    @Test("Decodes an uncompressed name into lowercase labels without the root dot")
    func decodesName() {
        #expect(decode(wire(["Replica-A", "abc123", "us-east-1", "rds", "amazonaws", "com"]))
            == "replica-a.abc123.us-east-1.rds.amazonaws.com")
    }

    @Test("Refuses compression pointers, truncation, the bare root, trailing bytes and dots inside a label")
    func refusesMalformedNames() {
        #expect(decode([0xC0, 0x0C]) == nil)
        #expect(decode([3, 0x61, 0x62]) == nil)
        #expect(decode([0]) == nil)
        #expect(decode(wire(["a", "com"]) + [1]) == nil)
        #expect(decode([3, 0x61, 0x2E, 0x62, 0]) == nil)
        #expect(decode([1, 0x00, 0]) == nil)
        for byte in [UInt8(ascii: " "), UInt8(ascii: "'"), UInt8(ascii: "="), UInt8(ascii: "/"), UInt8(ascii: ":"), 0xC3] {
            #expect(decode([3, 0x61, byte, 0x62, 3, 0x63, 0x6F, 0x6D, 0]) == nil)
        }
        #expect(decode(wire(["_dmarc", "example", "com"])) == "_dmarc.example.com")
        #expect(decode([64] + Array(repeating: 0x61, count: 64) + [0]) == nil)
    }
}
