//
//  View+OnValueChange.swift
//  TablePro
//

import SwiftUI

internal extension View {
    /// The two-value `onChange(of:_:)` is macOS 14. This keeps the previous value in local
    /// state so the single-value form can still report what it was.
    func onValueChange<Value: Equatable>(
        of value: Value,
        _ action: @escaping (Value, Value) -> Void
    ) -> some View {
        modifier(PairedValueChangeModifier(value: value, action: action))
    }
}

private struct PairedValueChangeModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value, Value) -> Void

    @State private var previous: Value?

    func body(content: Content) -> some View {
        content
            .onAppear { previous = value }
            .onChange(of: value) { current in
                let old = previous ?? current
                previous = current
                guard old != current else { return }
                action(old, current)
            }
    }
}
