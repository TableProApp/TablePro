//
//  InspectorMapSurfacePoolTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

/// The row inspector reissues every field's identity on a selection change, so without the pool
/// each arrow key builds a map per geometry field. A plain `NSView` stands in for the map here.
@MainActor
struct InspectorMapSurfacePoolTests {
    private final class FakeSurface: NSView, InspectorMapSurfacePooling {
        var prepared = 0
        var detached = 0

        func prepareForInspectorField() { prepared += 1 }
        func detachFromInspectorField() { detached += 1 }
    }

    /// Keeps every surface it built, so two of them never share an address in an identity check.
    @MainActor
    private final class Factory {
        private(set) var built: [FakeSurface] = []

        func make() -> FakeSurface {
            let surface = FakeSurface()
            built.append(surface)
            return surface
        }
    }

    @MainActor
    private final class ManualTimer {
        private var pending: [Int: (delay: Duration, action: @MainActor () -> Void)] = [:]
        private(set) var started = 0

        var pendingDelays: [Duration] { pending.values.map(\.delay) }

        func start(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            started += 1
            let id = started
            pending[id] = (delay, action)
            return { [weak self] in self?.pending[id] = nil }
        }

        func fire() {
            let due = pending.values.map(\.action)
            pending.removeAll()
            for action in due { action() }
        }
    }

    private typealias Pool = InspectorMapSurfacePool<FakeSurface>

    private func makePool(
        idleLimit: Int = 4,
        idleLifetime: Duration = .seconds(10),
        timer: ManualTimer = ManualTimer()
    ) -> (pool: Pool, factory: Factory) {
        let factory = Factory()
        let pool = Pool(
            idleLimit: idleLimit,
            idleLifetime: idleLifetime,
            startIdleTimer: timer.start,
            makeSurface: factory.make
        )
        return (pool, factory)
    }

    private func isSame(_ lhs: [FakeSurface], _ rhs: [FakeSurface]) -> Bool {
        Set(lhs.map(ObjectIdentifier.init)) == Set(rhs.map(ObjectIdentifier.init))
    }

    @Test("An empty pool builds a surface and prepares it")
    func takeBuildsWhenEmpty() {
        let (pool, factory) = makePool()
        let surface = pool.take()
        #expect(factory.built.count == 1)
        #expect(surface === factory.built.first)
        #expect(surface.prepared == 1)
        #expect(pool.idleCount == 0)
    }

    @Test("A surface given back is the next one taken, and is prepared again")
    func givenSurfaceIsReused() {
        let (pool, factory) = makePool()
        let first = pool.take()
        pool.give(first)
        #expect(pool.idleCount == 1)

        let second = pool.take()
        #expect(second === first)
        #expect(second.prepared == 2)
        #expect(factory.built.count == 1)
        #expect(pool.idleCount == 0)
    }

    @Test("Giving a surface back detaches it and takes it out of its host")
    func giveDetaches() {
        let (pool, _) = makePool()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 160))
        let surface = pool.take()
        host.addSubview(surface)

        pool.give(surface)
        #expect(surface.detached == 1)
        #expect(surface.superview == nil)
        #expect(host.subviews.isEmpty)
    }

    @Test("Make, make, dismantle, dismantle: two fields step rows on four surfaces in all")
    func makeBeforeDismantle() {
        let (pool, factory) = makePool()
        var mounted = [pool.take(), pool.take()]

        for _ in 0 ..< 20 {
            let next = [pool.take(), pool.take()]
            #expect(!next.contains { candidate in mounted.contains { $0 === candidate } })
            for surface in mounted { pool.give(surface) }
            mounted = next
        }
        #expect(factory.built.count == 4)
        #expect(pool.idleCount == 2)
    }

    @Test("Dismantle, dismantle, make, make: two fields step rows on the two surfaces they have")
    func dismantleBeforeMake() {
        let (pool, factory) = makePool()
        var mounted = [pool.take(), pool.take()]

        for step in 1 ... 20 {
            for surface in mounted { pool.give(surface) }
            let next = [pool.take(), pool.take()]
            #expect(isSame(next, mounted))
            #expect(next.allSatisfy { $0.prepared == step + 1 && $0.detached == step })
            mounted = next
        }
        #expect(factory.built.count == 2)
        #expect(pool.idleCount == 0)
    }

    @Test("Make, dismantle, make, dismantle: the orders can interleave within one step")
    func interleavedOrder() {
        let (pool, factory) = makePool()
        var mounted = [pool.take(), pool.take()]

        for _ in 0 ..< 20 {
            let first = pool.take()
            #expect(!mounted.contains { $0 === first })
            pool.give(mounted[0])
            let second = pool.take()
            #expect(second === mounted[0])
            pool.give(mounted[1])
            mounted = [first, second]
        }
        #expect(factory.built.count == 3)
        #expect(pool.idleCount == 1)
    }

    @Test("A surface given back twice is never handed to two fields")
    func doubleGiveIsNotDuplicated() {
        let (pool, factory) = makePool()
        let surface = pool.take()
        pool.give(surface)
        pool.give(surface)
        #expect(pool.idleCount == 1)

        let first = pool.take()
        let second = pool.take()
        #expect(first !== second)
        #expect(factory.built.count == 2)
    }

    @Test("At most four surfaces stay idle, and the ones let go are still detached")
    func idleIsCapped() {
        let (pool, factory) = makePool()
        let surfaces = (0 ..< 6).map { _ in pool.take() }
        for surface in surfaces { pool.give(surface) }

        #expect(pool.idleCount == 4)
        #expect(surfaces.allSatisfy { $0.detached == 1 })
        #expect(factory.built.count == 6)
    }

    @Test("Idle surfaces are let go once the delay passes, and the next take builds")
    func idleSurfacesAreReleasedAfterTheDelay() {
        let timer = ManualTimer()
        let (pool, factory) = makePool(idleLifetime: .seconds(7), timer: timer)
        let mounted = pool.take()
        pool.give(pool.take())
        #expect(pool.idleCount == 1)
        #expect(timer.pendingDelays == [.seconds(7)])

        timer.fire()
        #expect(pool.idleCount == 0)
        #expect(timer.pendingDelays.isEmpty)

        let next = pool.take()
        #expect(next !== mounted)
        #expect(factory.built.count == 3)
    }

    @Test("Every take and give starts the delay over, so stepping rows keeps the idle surfaces")
    func everyUseRestartsTheDelay() {
        let timer = ManualTimer()
        let (pool, _) = makePool(timer: timer)
        let first = pool.take()
        let second = pool.take()
        let third = pool.take()
        #expect(timer.started == 0)

        pool.give(first)
        pool.give(second)
        #expect(timer.started == 2)
        #expect(timer.pendingDelays.count == 1)

        _ = pool.take()
        #expect(timer.started == 3)
        #expect(timer.pendingDelays.count == 1)
        #expect(pool.idleCount == 1)

        pool.give(third)
        timer.fire()
        #expect(pool.idleCount == 0)
    }

    @Test("No delay runs while nothing is idle")
    func noTimerWithNothingIdle() {
        let timer = ManualTimer()
        let (pool, _) = makePool(timer: timer)
        let surface = pool.take()
        #expect(timer.pendingDelays.isEmpty)

        pool.give(surface)
        #expect(timer.pendingDelays.count == 1)

        _ = pool.take()
        #expect(timer.pendingDelays.isEmpty)
    }
}
