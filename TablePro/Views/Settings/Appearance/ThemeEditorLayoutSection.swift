//
//  ThemeEditorLayoutSection.swift
//  TablePro
//

import SwiftUI

internal struct ThemeEditorLayoutSection: View {
    private var engine: ThemeEngine { ThemeEngine.shared }
    private var theme: ThemeDefinition { engine.activeTheme }

    var body: some View {
        Form {
            typographySection
            spacingSection
            iconSizesSection
            cornerRadiusSection
            rowHeightsSection
            animationsSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Sections

    private var typographySection: some View {
        Section(String(localized: "Typography")) {
            numericField(String(localized: "Tiny"), keyPath: \.typography.tiny, range: 1...20)
            numericField(String(localized: "Caption"), keyPath: \.typography.caption, range: 1...20)
            numericField(String(localized: "Small"), keyPath: \.typography.small, range: 1...20)
            numericField(String(localized: "Medium"), keyPath: \.typography.medium, range: 1...20)
            numericField(String(localized: "Body"), keyPath: \.typography.body, range: 1...20)
            numericField(String(localized: "Title 3"), keyPath: \.typography.title3, range: 1...30)
            numericField(String(localized: "Title 2"), keyPath: \.typography.title2, range: 1...30)
        }
    }

    private var spacingSection: some View {
        Section(String(localized: "Spacing")) {
            numericField("xxxs", keyPath: \.spacing.xxxs, range: 0...10)
            numericField("xxs", keyPath: \.spacing.xxs, range: 0...20)
            numericField("xs", keyPath: \.spacing.xs, range: 0...30)
            numericField("sm", keyPath: \.spacing.sm, range: 0...30)
            numericField("md", keyPath: \.spacing.md, range: 0...40)
            numericField("lg", keyPath: \.spacing.lg, range: 0...40)
            numericField("xl", keyPath: \.spacing.xl, range: 0...50)
        }
    }

    private var iconSizesSection: some View {
        Section(String(localized: "Icon Sizes")) {
            numericField(String(localized: "Tiny Dot"), keyPath: \.iconSizes.tinyDot, range: 2...20)
            numericField(String(localized: "Status Dot"), keyPath: \.iconSizes.statusDot, range: 2...20)
            numericField(String(localized: "Small"), keyPath: \.iconSizes.small, range: 4...30)
            numericField(String(localized: "Default"), keyPath: \.iconSizes.default, range: 4...30)
            numericField(String(localized: "Medium"), keyPath: \.iconSizes.medium, range: 4...40)
            numericField(String(localized: "Large"), keyPath: \.iconSizes.large, range: 8...50)
            numericField(String(localized: "Extra Large"), keyPath: \.iconSizes.extraLarge, range: 8...60)
            numericField(String(localized: "Huge"), keyPath: \.iconSizes.huge, range: 16...80)
            numericField(String(localized: "Massive"), keyPath: \.iconSizes.massive, range: 32...128)
        }
    }

    private var cornerRadiusSection: some View {
        Section(String(localized: "Corner Radius")) {
            numericField(String(localized: "Small"), keyPath: \.cornerRadius.small, range: 0...20)
            numericField(String(localized: "Medium"), keyPath: \.cornerRadius.medium, range: 0...20)
            numericField(String(localized: "Large"), keyPath: \.cornerRadius.large, range: 0...30)
        }
    }

    private var rowHeightsSection: some View {
        Section(String(localized: "Row Heights")) {
            numericField(String(localized: "Compact"), keyPath: \.rowHeights.compact, range: 16...60)
            numericField(String(localized: "Table"), keyPath: \.rowHeights.table, range: 20...80)
            numericField(String(localized: "Comfortable"), keyPath: \.rowHeights.comfortable, range: 30...100)
        }
    }

    private var animationsSection: some View {
        Section(String(localized: "Animations")) {
            doubleField(String(localized: "Fast"), keyPath: \.animations.fast, range: 0.01...1.0)
            doubleField(String(localized: "Normal"), keyPath: \.animations.normal, range: 0.01...1.0)
            doubleField(String(localized: "Smooth"), keyPath: \.animations.smooth, range: 0.01...1.0)
            doubleField(String(localized: "Slow"), keyPath: \.animations.slow, range: 0.01...2.0)
        }
    }

    // MARK: - Binding Helpers

    private func binding(for keyPath: WritableKeyPath<ThemeDefinition, CGFloat>) -> Binding<CGFloat> {
        Binding<CGFloat>(
            get: { theme[keyPath: keyPath] },
            set: { newValue in
                guard theme.isEditable else { return }
                var updated = theme
                updated[keyPath: keyPath] = newValue
                try? engine.saveUserTheme(updated)
            }
        )
    }

    private func doubleBinding(for keyPath: WritableKeyPath<ThemeDefinition, Double>) -> Binding<Double> {
        Binding<Double>(
            get: { theme[keyPath: keyPath] },
            set: { newValue in
                guard theme.isEditable else { return }
                var updated = theme
                updated[keyPath: keyPath] = newValue
                try? engine.saveUserTheme(updated)
            }
        )
    }

    // MARK: - Row Helpers

    private func numericField(
        _ label: String,
        keyPath: WritableKeyPath<ThemeDefinition, CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat = 1
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("", value: binding(for: keyPath), formatter: NumberFormatter())
                    .frame(width: 60)
                Stepper("", value: binding(for: keyPath), in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private func doubleField(
        _ label: String,
        keyPath: WritableKeyPath<ThemeDefinition, Double>,
        range: ClosedRange<Double>,
        step: Double = 0.05
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("", value: doubleBinding(for: keyPath), format: .number.precision(.fractionLength(2)))
                    .frame(width: 60)
                Stepper("", value: doubleBinding(for: keyPath), in: range, step: step)
                    .labelsHidden()
            }
        }
    }
}
