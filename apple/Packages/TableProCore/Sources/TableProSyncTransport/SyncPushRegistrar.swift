// Each app supplies its own: AppKit and UIKit answer a registration through the app delegate.
public struct SyncPushRegistrar: Sendable {
    public let register: @MainActor @Sendable () -> Void
    public let unregister: @MainActor @Sendable () -> Void

    public init(
        register: @escaping @MainActor @Sendable () -> Void,
        unregister: @escaping @MainActor @Sendable () -> Void
    ) {
        self.register = register
        self.unregister = unregister
    }
}
