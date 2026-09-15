//
//  SourceEditorConfiguration+Behavior.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 6/16/25.
//

public extension SourceEditorConfiguration {
    struct Behavior: Equatable {
        /// Controls whether the text view allows the user to edit text.
        public var isEditable: Bool = true

        /// Controls whether the text view allows the user to select text. If this value is true, and `isEditable` is
        /// false, the editor is selectable but not editable.
        public var isSelectable: Bool = true

        /// Determines what character(s) to insert when the tab key is pressed. Defaults to 4 spaces.
        public var indentOption: IndentOption = .spaces(count: 4)

        public init(
            isEditable: Bool = true,
            isSelectable: Bool = true,
            indentOption: IndentOption = .spaces(count: 4)
        ) {
            self.isEditable = isEditable
            self.isSelectable = isSelectable
            self.indentOption = indentOption
        }

        @MainActor
        func didSetOnController(controller: TextViewController, oldConfig: Behavior?) {
            if oldConfig?.isEditable != isEditable {
                controller.textView.isEditable = isEditable
                controller.textView.selectionManager.highlightSelectedLine = isEditable
                controller.gutterView.highlightSelectedLines = isEditable
                if !isEditable {
                    controller.gutterView.selectedLineTextColor = nil
                    controller.gutterView.selectedLineColor = .clear
                }
            }

            if oldConfig?.isSelectable != isSelectable {
                controller.textView.isSelectable = isSelectable
            }

            if oldConfig?.indentOption != indentOption {
                controller.setUpTextFormation()
            }
        }
    }
}
