import Foundation

// Holds work at a known point until the test lets it go.
actor TestGate {
    private var isOpen = false
    private var hasEntered = false
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        hasEntered = true
        for observer in observers { observer.resume() }
        observers.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { blocked.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in blocked { waiter.resume() }
        blocked.removeAll()
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { observers.append($0) }
    }
}
