import Observation

@MainActor
enum ObservedCondition {
    static func wait(until condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = condition()
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}
