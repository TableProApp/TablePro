//
//  RoutineDebugStartSheet.swift
//  TablePro
//

import Combine
import SwiftUI
import TableProPluginKit

@MainActor
internal final class RoutineDebugStartModel: ObservableObject {
    struct Argument: Identifiable, Equatable {
        let id: Int
        let parameter: PluginDebugParameter
        var text = ""
        var isNull = false
        var usesDefault = false

        var takesValue: Bool {
            parameter.mode != .output
        }

        var value: PluginDebugArgumentValue {
            if usesDefault { return .defaultValue }
            if isNull { return .null }
            return .text(text)
        }
    }

    let plan: PluginDebugPlan
    @Published private(set) var entryPointIndex = 0
    @Published private(set) var arguments: [Argument] = []
    @Published private(set) var optionValues: [String: String] = [:]

    init(plan: PluginDebugPlan, rememberedOption: (String) -> String?) {
        self.plan = plan
        for field in plan.options {
            optionValues[field.id] = field.isSecure ? field.defaultValue ?? "" : rememberedOption(field.id) ?? field.defaultValue ?? ""
        }
        arguments = Self.arguments(for: plan.entryPoints.first)
    }

    var entryPoint: PluginDebugEntryPoint? {
        plan.entryPoints.indices.contains(entryPointIndex) ? plan.entryPoints[entryPointIndex] : nil
    }

    func selectEntryPoint(_ index: Int) {
        guard plan.entryPoints.indices.contains(index), index != entryPointIndex else { return }
        entryPointIndex = index
        arguments = Self.arguments(for: plan.entryPoints[index])
    }

    func setText(_ text: String, for id: Int) {
        update(id) { $0.text = text }
    }

    func setNull(_ isNull: Bool, for id: Int) {
        update(id) { argument in
            argument.isNull = isNull
            if isNull { argument.usesDefault = false }
        }
    }

    func setUsesDefault(_ usesDefault: Bool, for id: Int) {
        update(id) { argument in
            argument.usesDefault = usesDefault
            if usesDefault { argument.isNull = false }
        }
    }

    func setOption(_ value: String, for fieldId: String) {
        optionValues[fieldId] = value
    }

    func isVisible(_ field: ConnectionField) -> Bool {
        guard let rule = field.visibleWhen else { return true }
        return rule.values.contains(optionValues[rule.fieldId] ?? "")
    }

    func choice() -> RoutineDebugStartChoice? {
        guard let entryPoint else { return nil }
        return RoutineDebugStartChoice(
            entryPoint: entryPoint,
            arguments: arguments.filter(\.takesValue).map {
                PluginDebugArgument(parameterName: $0.parameter.name, value: $0.value)
            },
            optionValues: optionValues.filter { id, _ in
                plan.options.contains { $0.id == id && isVisible($0) }
            }
        )
    }

    // One whole-value write, so a NULL tick and the text it clears land together.
    private func update(_ id: Int, _ change: (inout Argument) -> Void) {
        guard let index = arguments.firstIndex(where: { $0.id == id }) else { return }
        var argument = arguments[index]
        change(&argument)
        arguments[index] = argument
    }

    private static func arguments(for entryPoint: PluginDebugEntryPoint?) -> [Argument] {
        (entryPoint?.parameters ?? []).enumerated().map { index, parameter in
            Argument(id: index, parameter: parameter, usesDefault: parameter.hasDefault)
        }
    }
}

internal struct RoutineDebugStartSheet: View {
    @StateObject private var model: RoutineDebugStartModel
    let onFinish: @MainActor (RoutineDebugStartChoice?) -> Void

    init(model: RoutineDebugStartModel, onFinish: @escaping @MainActor (RoutineDebugStartChoice?) -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onFinish = onFinish
    }

    static func present(
        plan: PluginDebugPlan,
        rememberedOption: (String) -> String?,
        on window: NSWindow,
        setup: RoutineDebugSetup
    ) async -> RoutineDebugStartChoice? {
        let model = RoutineDebugStartModel(plan: plan, rememberedOption: rememberedOption)
        return await RoutineDebugSheet.present(on: window, setup: setup) { finish in
            RoutineDebugStartSheet(model: model, onFinish: finish)
        }
    }

    // Secrets stay out of defaults; the plan supplies them again next time.
    static func rememberedValues(of choice: RoutineDebugStartChoice, in plan: PluginDebugPlan) -> [String: String] {
        let secure = Set(plan.options.filter(\.isSecure).map(\.id))
        return choice.optionValues.filter { !secure.contains($0.key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(format: String(localized: "Debug %@"), model.plan.target.name))
                .font(.headline)

            if model.plan.entryPoints.count > 1 {
                Picker(String(localized: "Entry Point"), selection: entryPointBinding) {
                    ForEach(Array(model.plan.entryPoints.enumerated()), id: \.offset) { index, entryPoint in
                        Text(entryPoint.displayName).tag(index)
                    }
                }
            }

            if model.arguments.isEmpty {
                Text(String(localized: "This routine takes no arguments."))
                    .foregroundStyle(.secondary)
            } else {
                argumentTable
            }

            if !model.plan.options.isEmpty {
                Form {
                    ForEach(model.plan.options.filter { model.isVisible($0) }, id: \.id) { field in
                        optionRow(field)
                    }
                }
            }

            if let note = model.plan.note, !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) {
                    onFinish(nil)
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "Debug")) {
                    onFinish(model.choice())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.entryPoint == nil)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private var entryPointBinding: Binding<Int> {
        Binding(get: { model.entryPointIndex }, set: { model.selectEntryPoint($0) })
    }

    // The ideal widths plus the table's insets and column gaps stay inside the sheet, or Default scrolls out of sight.
    private var argumentTable: some View {
        Table(model.arguments) {
            TableColumn(String(localized: "Name")) { argument in
                Text(argument.parameter.name)
            }
            .width(min: 80, ideal: 100)
            TableColumn(String(localized: "Type")) { argument in
                Text(argument.parameter.typeName)
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn(String(localized: "Value")) { argument in
                if argument.takesValue {
                    TextField(
                        String(localized: "Value"),
                        text: Binding(get: { argument.text }, set: { model.setText($0, for: argument.id) })
                    )
                    .labelsHidden()
                    .disabled(argument.isNull || argument.usesDefault)
                } else {
                    Text(String(localized: "Output"))
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 120, ideal: 140)
            TableColumn(String(localized: "NULL")) { argument in
                Toggle(
                    String(localized: "NULL"),
                    isOn: Binding(get: { argument.isNull }, set: { model.setNull($0, for: argument.id) })
                )
                .labelsHidden()
                .disabled(!argument.takesValue)
            }
            .width(48)
            TableColumn(String(localized: "Default")) { argument in
                Toggle(
                    String(localized: "Default"),
                    isOn: Binding(get: { argument.usesDefault }, set: { model.setUsesDefault($0, for: argument.id) })
                )
                .labelsHidden()
                .disabled(!argument.takesValue || !argument.parameter.hasDefault)
            }
            .width(56)
        }
        .frame(height: min(CGFloat(model.arguments.count) * 28 + 32, 220))
    }

    @ViewBuilder
    private func optionRow(_ field: ConnectionField) -> some View {
        let binding = Binding(
            get: { model.optionValues[field.id] ?? "" },
            set: { model.setOption($0, for: field.id) }
        )
        switch field.fieldType {
        case .dropdown(let options):
            Picker(field.label, selection: binding) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        case .toggle:
            Toggle(
                field.label,
                isOn: Binding(
                    get: { binding.wrappedValue == "true" },
                    set: { binding.wrappedValue = $0 ? "true" : "false" }
                )
            )
        case .secure:
            SecureField(field.label, text: binding, prompt: Text(field.placeholder))
        default:
            TextField(field.label, text: binding, prompt: Text(field.placeholder))
        }
    }
}
