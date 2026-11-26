//
//  Atomic.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 9/2/24.
//

import Foundation

/// A simple atomic value using `NSLock`.
final package class Atomic<T> {
    private let lock: NSLock = .init()
    private var wrappedValue: T

    init(_ wrappedValue: T) {
        self.wrappedValue = wrappedValue
    }

    @discardableResult
    func mutate<R>(_ handler: (inout T) -> R) -> R {
        lock.withLock {
            handler(&wrappedValue)
        }
    }

    func withValue<F>(_ handler: (T) -> F) -> F {
        lock.withLock { handler(wrappedValue) }
    }

    func value() -> T {
        lock.withLock { wrappedValue }
    }
}
