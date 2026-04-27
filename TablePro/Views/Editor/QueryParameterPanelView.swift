//
//  QueryParameterPanelView.swift
//  TablePro
//

import SwiftUI

extension QueryParameterType {
    var displayName: String {
        switch self {
        case .string: return "String"
        case .integer: return "Integer"
        case .decimal: return "Decimal"
        case .date: return "Date"
        case .boolean: return "Boolean"
        }
    }
}

struct QueryParameterPanelView: View {
    @Binding var parameters: [QueryParameter]
    var onDismiss: () -> Void

    private let maxParameterListHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            panelHeader

            Divider()
                .foregroundStyle(Color(nsColor: .separatorColor))

            if !parameters.isEmpty {
                parameterList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Text("Parameters")
                .font(.callout.weight(.medium))

            Spacer()

            Button("Clear All") {
                for index in parameters.indices {
                    parameters[index].value = ""
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Close parameter panel"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var parameterRows: some View {
        VStack(spacing: 0) {
            ForEach(parameters) { parameter in
                QueryParameterRowView(
                    parameter: Binding(
                        get: {
                            parameters.first(where: { $0.id == parameter.id }) ?? parameter
                        },
                        set: { newValue in
                            if let idx = parameters.firstIndex(where: { $0.id == parameter.id }) {
                                parameters[idx] = newValue
                            }
                        }
                    )
                )
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var parameterList: some View {
        let estimatedHeight = CGFloat(parameters.count) * 32 + 8
        if estimatedHeight > maxParameterListHeight {
            ScrollView {
                parameterRows
            }
            .frame(maxHeight: maxParameterListHeight)
        } else {
            parameterRows
        }
    }
}

struct QueryParameterRowView: View {
    @Binding var parameter: QueryParameter

    var body: some View {
        HStack(spacing: 8) {
            Text(":\(parameter.name)")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)

            TextField(parameter.type.displayName, text: $parameter.value)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .disabled(parameter.isNull)

            Picker("", selection: $parameter.type) {
                ForEach(QueryParameterType.allCases, id: \.self) { paramType in
                    Text(paramType.displayName).tag(paramType)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .labelsHidden()
            .frame(width: 90)

            Toggle("NULL", isOn: $parameter.isNull)
                .controlSize(.small)
                .toggleStyle(.checkbox)
                .frame(width: 60)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

#Preview("Parameter Panel") {
    QueryParameterPanelView(
        parameters: .constant([
            QueryParameter(name: "user_id", value: "42", type: .integer),
            QueryParameter(name: "name", value: "John", type: .string),
            QueryParameter(name: "created_at", type: .date, isNull: true)
        ]),
        onDismiss: {}
    )
    .frame(width: 600)
}
