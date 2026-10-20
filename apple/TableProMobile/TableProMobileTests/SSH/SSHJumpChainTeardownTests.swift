import Foundation
import os
import TableProSSHTransport
import Testing

@testable import TableProMobile

struct SSHJumpChainTeardownTests {
    @Test("Every relay is woken and its socket shut down, then every relay is waited on, then each hop is freed once", .timeLimit(.minutes(1)))
    func wakesThenWaitsThenFrees() async throws {
        let log = TeardownLog()
        let chain = try HopChain(count: 3, log: log)
        defer { chain.close() }

        let teardown = Task {
            await SSHJumpChain.tearDown(chain.hops) { hop in log.append("free \(chain.index(of: hop))") }
        }

        await chain.waitForStops(3)
        #expect(chain.everyHopSocketReadsEOF())
        #expect(!log.events.contains { $0.hasPrefix("free") })

        chain.finishRelays()
        await teardown.value

        let events = log.events
        #expect(events.filter { $0.hasPrefix("stop") } == ["stop 2", "stop 1", "stop 0"])
        #expect(events.filter { $0.hasPrefix("free") } == ["free 2", "free 1", "free 0"])
        let lastStop = try #require(events.lastIndex { $0.hasPrefix("stop") })
        let firstFinish = try #require(events.firstIndex { $0.hasPrefix("finished") })
        let lastFinish = try #require(events.lastIndex { $0.hasPrefix("finished") })
        let firstFree = try #require(events.firstIndex { $0.hasPrefix("free") })
        #expect(lastStop < firstFinish)
        #expect(lastFinish < firstFree)
    }

    @Test("A relay that already ended is not stopped again, and its hop is still shut down and freed", .timeLimit(.minutes(1)))
    func endedRelayIsStillFreed() async throws {
        let log = TeardownLog()
        let chain = try HopChain(count: 2, log: log)
        defer { chain.close() }
        chain.finishRelay(0)

        let teardown = Task {
            await SSHJumpChain.tearDown(chain.hops) { hop in log.append("free \(chain.index(of: hop))") }
        }
        await chain.waitForStops(1)
        #expect(chain.everyHopSocketReadsEOF())
        chain.finishRelay(1)
        await teardown.value

        let events = log.events
        #expect(events.filter { $0.hasPrefix("stop") } == ["stop 1"])
        #expect(events.filter { $0.hasPrefix("free") } == ["free 1", "free 0"])
    }
}

private final class TeardownLog: Sendable {
    private let entries = OSAllocatedUnfairLock<[String]>(initialState: [])

    var events: [String] { entries.withLock { $0 } }

    func append(_ event: String) {
        entries.withLock { $0.append(event) }
    }
}

// Real fences over real socketpairs. The libssh2 handles are placeholders the recorded free never touches.
private final class HopChain: Sendable {
    struct SetupFailure: Error {}

    let hops: [SSHJumpHop]
    private let peers: [Int32]
    private let stops: AsyncStream<Int>
    private let log: TeardownLog

    init(count: Int, log: TeardownLog) throws {
        let (stops, stopped) = AsyncStream<Int>.makeStream()
        var hops: [SSHJumpHop] = []
        var peers: [Int32] = []
        for index in 0 ..< count {
            var fds: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0,
                  let session = OpaquePointer(bitPattern: 0x1_000 + index),
                  let channel = OpaquePointer(bitPattern: 0x2_000 + index) else { throw SetupFailure() }
            let relay = SSHJumpRelayFence {
                log.append("stop \(index)")
                stopped.yield(index)
            }
            hops.append(SSHJumpHop(
                session: session,
                socketFD: fds[0],
                channel: channel,
                relay: relay,
                sessionQueue: DispatchQueue(label: "com.TablePro.tests.hop.\(index)")
            ))
            peers.append(fds[1])
        }
        self.hops = hops
        self.peers = peers
        self.stops = stops
        self.log = log
    }

    func index(of hop: SSHJumpHop) -> Int {
        hops.firstIndex { $0.socketFD == hop.socketFD } ?? -1
    }

    func waitForStops(_ expected: Int) async {
        var seen = 0
        for await _ in stops {
            seen += 1
            if seen == expected { return }
        }
    }

    func finishRelay(_ index: Int) {
        let log = self.log
        hops[index].relay.finish { log.append("finished \(index)") }
    }

    func finishRelays() {
        for index in hops.indices {
            finishRelay(index)
        }
    }

    func everyHopSocketReadsEOF() -> Bool {
        peers.allSatisfy { peer in
            var pollFD = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, 2_000) > 0 else { return false }
            var byte: UInt8 = 0
            return recv(peer, &byte, 1, 0) == 0
        }
    }

    func close() {
        for hop in hops { Darwin.close(hop.socketFD) }
        for peer in peers { Darwin.close(peer) }
    }
}
