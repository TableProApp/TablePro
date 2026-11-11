import dnssd
import Foundation

// A lookup that failed is kept apart from a name with no CNAME: only the second is an answer. The three cases are
// every outcome a lookup has, so the enum is frozen.
@frozen
public enum CNAMELookup: Sendable, Equatable {
    case found(String)
    case notFound
    case failed
}

public protocol CNAMEResolving: Sendable {
    // The target of `name`'s CNAME record: `notFound` when DNS says it has none, `failed` when the lookup errs or
    // runs out of `timeout`.
    func cnameTarget(of name: String, within timeout: Duration?) async -> CNAMELookup
}

public extension CNAMEResolving {
    // Follows the chain one record at a time, so it can stop at a name in the middle: the end of an RDS chain is an
    // EC2, VPC endpoint or replica name that no token is signed for. A loop or an over-long chain finds nothing.
    func firstName(
        behind host: String,
        within timeout: Duration?,
        where matches: (String) -> Bool
    ) async -> CNAMELookup {
        let clock = ContinuousClock()
        let deadline = timeout.map { clock.now.advanced(by: $0) }
        var visited: Set<String> = [DNSWireName.normalized(host)]
        var current = host
        for _ in 0 ..< DNSWireName.maximumChainLength {
            let remaining = deadline.map { clock.now.duration(to: $0) }
            if let remaining, remaining <= .zero {
                return .failed
            }
            switch await cnameTarget(of: current, within: remaining) {
            case .found(let target):
                if matches(target) {
                    return .found(target)
                }
                guard visited.insert(target).inserted else { return .notFound }
                current = target
            case .notFound:
                return .notFound
            case .failed:
                return .failed
            }
        }
        return .notFound
    }
}

// The system resolver, which is what the driver's own lookup uses: it follows VPN split DNS and scoped resolvers,
// and libresolv does not.
public struct SystemCNAMEResolver: CNAMEResolving {
    public init() {}

    public func cnameTarget(of name: String, within timeout: Duration?) async -> CNAMELookup {
        let query = CNAMEQuery(name: name)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                query.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            query.cancel()
        }
    }
}

enum DNSWireName {
    static let maximumChainLength = 8

    static func normalized(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    // dnssd hands over the record's rdata uncompressed, so a pointer here means a malformed answer.
    static func decode(_ bytes: UnsafeRawBufferPointer) -> String? {
        var labels: [String] = []
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            if length == 0 {
                guard !labels.isEmpty, index == bytes.count else { return nil }
                let name = labels.joined(separator: ".")
                return name.utf8.count <= 253 ? name : nil
            }
            guard length <= 63, index + length <= bytes.count else { return nil }
            let label = bytes[index ..< index + length]
            // The name can become the host a driver dials, so it holds only what a host name may.
            guard label.allSatisfy(isHostNameByte), let text = String(bytes: label, encoding: .ascii) else { return nil }
            labels.append(text.lowercased())
            index += length
        }
        return nil
    }

    private static func isHostNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "A") ... UInt8(ascii: "Z"),
             UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }
}

// dnssd delivers on the queue a ref was given and wants the ref deallocated there, so all state lives on that queue.
private final class CNAMEQuery: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.TablePro.CNAMEQuery")

    private let name: String
    private var ref: DNSServiceRef?
    private var retained: Unmanaged<CNAMEQuery>?
    private var continuation: CheckedContinuation<CNAMELookup, Never>?
    private var isFinished = false

    init(name: String) {
        self.name = DNSWireName.normalized(name)
    }

    func start(timeout: Duration?, continuation: CheckedContinuation<CNAMELookup, Never>) {
        Self.queue.async {
            guard !self.isFinished else {
                continuation.resume(returning: .failed)
                return
            }
            self.continuation = continuation
            if let timeout, timeout <= .zero {
                self.finish(.failed)
                return
            }
            let retained = Unmanaged.passRetained(self)
            self.retained = retained
            var ref: DNSServiceRef?
            // Without ReturnIntermediates a name with no CNAME never answers, and the query waits out the system
            // timeout of about 30 seconds (measured).
            let status = DNSServiceQueryRecord(
                &ref,
                DNSServiceFlags(kDNSServiceFlagsReturnIntermediates | kDNSServiceFlagsTimeout),
                UInt32(kDNSServiceInterfaceIndexAny),
                self.name,
                UInt16(kDNSServiceType_CNAME),
                UInt16(kDNSServiceClass_IN),
                { _, flags, _, error, fullname, rrtype, _, length, rdata, _, context in
                    guard let context else { return }
                    let query = Unmanaged<CNAMEQuery>.fromOpaque(context).takeUnretainedValue()
                    let owner = fullname.map { String(cString: $0) }
                    let bytes = rdata.map { UnsafeRawBufferPointer(start: $0, count: Int(length)) }
                    query.receive(flags: flags, error: error, owner: owner, rrtype: rrtype, rdata: bytes)
                },
                retained.toOpaque()
            )
            guard status == kDNSServiceErr_NoError, let ref else {
                self.finish(.failed)
                return
            }
            self.ref = ref
            DNSServiceSetDispatchQueue(ref, Self.queue)
            if let timeout {
                Self.queue.asyncAfter(deadline: .now() + Self.seconds(timeout)) {
                    self.finish(.failed)
                }
            }
        }
    }

    func cancel() {
        Self.queue.async {
            self.finish(.failed)
        }
    }

    private func receive(
        flags: DNSServiceFlags,
        error: DNSServiceErrorType,
        owner: String?,
        rrtype: UInt16,
        rdata: UnsafeRawBufferPointer?
    ) {
        guard !isFinished else { return }
        guard error == kDNSServiceErr_NoError else {
            // With ReturnIntermediates, NoSuchRecord is DNS saying the name has no CNAME, or does not exist.
            finish(error == kDNSServiceErr_NoSuchRecord ? .notFound : .failed)
            return
        }
        guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
              Int(rrtype) == kDNSServiceType_CNAME,
              owner.map(DNSWireName.normalized) == name,
              let rdata
        else { return }
        finish(DNSWireName.decode(rdata).map(CNAMELookup.found) ?? .failed)
    }

    // A cancel can land before the start block runs: it marks the query finished, and the start block then resumes
    // the continuation it was handed.
    private func finish(_ outcome: CNAMELookup) {
        guard !isFinished else { return }
        isFinished = true
        if let ref {
            DNSServiceRefDeallocate(ref)
            self.ref = nil
        }
        if let continuation {
            continuation.resume(returning: outcome)
            self.continuation = nil
        }
        retained?.release()
        retained = nil
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
