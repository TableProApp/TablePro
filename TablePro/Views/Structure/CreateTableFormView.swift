//
//  CreateTableFormView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

internal struct CreateTableFormView: View {
    @ObservedObject internal var draft: CreateTableDraft

    internal var body: some View {
        if let form = draft.form {
            Form {
                ForEach(Array(form.spec.sections.enumerated()), id: \.element.id) { offset, section in
                    CreateTableFormSectionView(
                        draft: draft,
                        form: form,
                        section: section,
                        footnote: offset == form.spec.sections.count - 1 ? form.spec.footnote : nil
                    )
                }
            }
            .formStyle(.grouped)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("create-table-form")
        }
    }
}
