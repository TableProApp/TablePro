//
//  TabReplacementFilter.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 1/28/23.
//

import Foundation
import TextFormation
import TextStory

/// Filter for replacing tab characters with the user-defined indentation unit.
/// - Note: The undentation unit can be another tab character, this is merely a point at which this can be configured.
struct TabReplacementFilter: Filter {
    let indentOption: IndentOption

    func processMutation(
        _ mutation: TextMutation,
        in interface: TextInterface,
        with providers: WhitespaceProviders
    ) -> FilterAction {
        if mutation.string == "\t" && indentOption != .tab && mutation.delta > 0 {
            interface.applyMutation(
                TextMutation(
                    insert: indentOption.stringValue,
                    at: mutation.range.location,
                    limit: mutation.limit
                )
            )
            return .discard
        } else {
            return .none
        }
    }
}
