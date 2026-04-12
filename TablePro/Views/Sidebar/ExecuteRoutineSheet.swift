import SwiftUI

struct ExecuteRoutineSheet: View {
    @Environment(\.dismiss) private var dismiss

    let routineName: String
    let routineType: RoutineInfo.RoutineType
    let parameters: [RoutineParameterInfo]
    let databaseType: DatabaseType
    let onExecute: (String) -> Void

    @State private var paramValues: [String] = []

    private var inputParameters: [RoutineParameterInfo] {
        parameters.filter { $0.direction.uppercased() != "RETURN" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            parameterInputs
            sqlPreview
            Divider()
            buttons
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            paramValues = Array(repeating: "", count: inputParameters.count)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: routineType == .function ? "function" : "gearshape.2")
                .font(.title2)
                .foregroundStyle(routineType == .function ? .purple : .teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(routineName)
                    .font(.headline)
                Text(routineType == .function
                    ? String(localized: "Function")
                    : String(localized: "Procedure"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Parameter Inputs

    @ViewBuilder
    private var parameterInputs: some View {
        if inputParameters.isEmpty {
            Text("No input parameters")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Parameters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(inputParameters.enumerated()), id: \.offset) { index, param in
                    HStack {
                        Text(param.name ?? "param\(index + 1)")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 120, alignment: .trailing)
                        TextField(param.dataType, text: paramValueBinding(at: index))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
    }

    private func paramValueBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { index < paramValues.count ? paramValues[index] : "" },
            set: { newValue in
                while paramValues.count <= index { paramValues.append("") }
                paramValues[index] = newValue
            }
        )
    }

    // MARK: - SQL Preview

    private var sqlPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "SQL Preview"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(generateSQL())
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: ThemeEngine.shared.activeTheme.cornerRadius.small))
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Execute")) {
                onExecute(generateSQL())
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - SQL Generation

    private func generateSQL() -> String {
        let values = inputParameters.enumerated().map { index, _ in
            let val = index < paramValues.count ? paramValues[index] : ""
            return val.isEmpty ? "NULL" : formatValue(val)
        }

        switch databaseType {
        case .mssql:
            return generateMSSQLSQL(values: values)
        default:
            return generateStandardSQL(values: values)
        }
    }

    private func generateStandardSQL(values: [String]) -> String {
        let argList = values.joined(separator: ", ")
        if routineType == .procedure {
            return "CALL \(routineName)(\(argList));"
        } else {
            return "SELECT \(routineName)(\(argList));"
        }
    }

    private func generateMSSQLSQL(values: [String]) -> String {
        if routineType == .procedure {
            if inputParameters.isEmpty {
                return "EXEC \(routineName);"
            }
            let assignments = inputParameters.enumerated().map { index, param in
                let name = param.name ?? "param\(index + 1)"
                let val = index < values.count ? values[index] : "NULL"
                return "@\(name) = \(val)"
            }
            return "EXEC \(routineName) \(assignments.joined(separator: ", "));"
        } else {
            let argList = values.joined(separator: ", ")
            return "SELECT dbo.\(routineName)(\(argList));"
        }
    }

    private func formatValue(_ value: String) -> String {
        if Int64(value) != nil || (Double(value) != nil && value.contains(".")) {
            return value
        }
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }
}
