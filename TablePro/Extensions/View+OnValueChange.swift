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

    /// The same, for a value that belongs to an object this view does not observe.
    ///
    /// A body that reads `parent.child.value` never hears the child change: `@Published` on the
    /// child publishes on the child alone, and observing the parent covers only the parent's own
    /// properties. The modifier observes the object instead of the view, so the object's other
    /// changes redraw nothing but the modifier.
    func onValueChange<Object: ObservableObject, Value: Equatable>(
        of keyPath: KeyPath<Object, Value>,
        in object: Object,
        _ action: @escaping (Value, Value) -> Void
    ) -> some View {
        modifier(ObservedValueChangeModifier(object: object, keyPath: keyPath, action: action))
    }
}

private struct ObservedValueChangeModifier<Object: ObservableObject, Value: Equatable>: ViewModifier {
    @ObservedObject var object: Object
    let keyPath: KeyPath<Object, Value>
    let action: (Value, Value) -> Void

    func body(content: Content) -> some View {
        content.onValueChange(of: object[keyPath: keyPath], action)
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
