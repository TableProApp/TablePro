//
//  NSEdgeInsets+Helpers.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/15/25.
//

import Foundation

extension NSEdgeInsets {
    var vertical: CGFloat {
        top + bottom
    }

    var horizontal: CGFloat {
        left + right
    }
}
