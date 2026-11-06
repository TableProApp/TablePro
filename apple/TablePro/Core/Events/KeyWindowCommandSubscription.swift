//
//  KeyWindowCommandSubscription.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
internal enum KeyWindowCommandSubscription {
    internal static func sink<Payload>(
        _ publisher: PassthroughSubject<Payload, Never>,
        when isFrontmost: @escaping @MainActor () -> Bool,
        perform handler: @escaping @MainActor (Payload) -> Void
    ) -> AnyCancellable {
        publisher
            .receive(on: RunLoop.main)
            .sink { payload in
                guard isFrontmost() else { return }
                handler(payload)
            }
    }
}
