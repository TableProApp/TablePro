import Foundation
import os
import TableProPluginKit

struct RDSDiscoveryClient: Sendable {
    static let apiVersion = "2014-10-31"
    static let recordsPerPage = 100
    static let pageLimit = 50

    private static let logger = Logger(subsystem: "com.TablePro", category: "RDSDiscovery")

    private let credentials: AWSCredentials
    private let session: URLSession
    private let clock: @Sendable () -> Date

    init(
        credentials: AWSCredentials,
        session: URLSession = AWSHTTP.shared,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.session = session
        self.clock = clock
    }

    func describeInstances(region: String) async throws -> [RDSInstance] {
        try await fetchAll(action: "DescribeDBInstances", region: region) {
            RDSDescribeResponseParser.parseInstances($0)
        }
    }

    func describeClusters(region: String) async throws -> [RDSCluster] {
        try await fetchAll(action: "DescribeDBClusters", region: region) {
            RDSDescribeResponseParser.parseClusters($0)
        }
    }

    private func fetchAll<Item>(
        action: String,
        region: String,
        parse: (Data) -> RDSDescribePage<Item>?
    ) async throws -> [Item] {
        var items: [Item] = []
        var marker: String?

        for _ in 0 ..< Self.pageLimit {
            try Task.checkCancellation()
            let data = try await send(action: action, region: region, marker: marker)
            guard let page = parse(data) else {
                throw RDSDiscoveryError.malformedResponse(region: region)
            }
            items.append(contentsOf: page.items)
            guard let next = page.marker, !next.isEmpty, next != marker else { break }
            marker = next
        }

        return items
    }

    private func send(action: String, region: String, marker: String?) async throws -> Data {
        var parameters = [
            "Action": action,
            "Version": Self.apiVersion,
            "MaxRecords": String(Self.recordsPerPage)
        ]
        if let marker {
            parameters["Marker"] = marker
        }

        let query = AWSQueryRequest(service: "rds", region: region, parameters: parameters)
        let request: URLRequest
        do {
            request = try query.signedURLRequest(credentials: credentials, now: clock())
        } catch {
            throw RDSDiscoveryError.invalidRegion(region: region)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            Self.logger.error("RDS \(action, privacy: .public) in \(region, privacy: .public) failed to send")
            throw RDSDiscoveryError.network(region: region, detail: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RDSDiscoveryError.malformedResponse(region: region)
        }
        guard http.statusCode == 200 else {
            let failure = AWSQueryErrorResponse.parse(data)
            let code = failure?.code ?? "HTTP \(http.statusCode)"
            Self.logger.error(
                """
                RDS \(action, privacy: .public) in \(region, privacy: .public) \
                returned \(http.statusCode, privacy: .public) \(code, privacy: .public)
                """
            )
            throw RDSDiscoveryError.mapping(code: code, message: failure?.message ?? "", region: region)
        }

        return data
    }
}
