//
//  EnumPickerView.swift
//  TablePro
//

import SwiftUI

internal struct EnumPickerView: View {
    let context: FieldEditorContext
    let values: [String]
    var isPendingNull: Bool = false
    var isPendingDefault: Bool = false
    var onSetNull: (() -> Void)?
    var onSetDefault: (() -> Void)?

    private static let nullSentinel = "\u{FFFE}NULL"
    private static let defaultSentinel = "\u{FFFE}DEFAULT"

    var body: some View {
        let isNullValue = context.originalValue == nil && !isPendingDefault
        let displayValue: String = {
            if isPendingNull || isNullValue { return Self.nullSentinel }
            if isPendingDefault { return Self.defaultSentinel }
            return context.value.wrappedValue
        }()

        Picker(selection: Binding(
            get: { displayValue },
            set: { newValue in
                switch newValue {
                case Self.nullSentinel: onSetNull?()
                case Self.defaultSentinel: onSetDefault?()
                default: context.value.wrappedValue = newValue
                }
            }
        )) {
            if isPendingNull || isNullValue {
                Text("NULL").tag(Self.nullSentinel)
            }
            if isPendingDefault {
                Text("DEFAULT").tag(Self.defaultSentinel)
            }
            ForEach(values, id: \.self) { val in
                Text(val).tag(val)
            }
            let showSetNull = onSetNull != nil && !isPendingNull && !isNullValue
            let showSetDefault = onSetDefault != nil && !isPendingDefault
            if showSetNull || showSetDefault {
                Divider()
                if showSetNull {
                    Text("Set NULL").tag(Self.nullSentinel)
                }
                if showSetDefault {
                    Text("Set DEFAULT").tag(Self.defaultSentinel)
                }
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(context.isReadOnly)
    }
}
