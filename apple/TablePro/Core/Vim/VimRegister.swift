//
//  VimRegister.swift
//  TablePro
//

import Foundation

struct VimRegister {
    var text: String = ""
    var isLinewise: Bool = false

    @MainActor
    func syncToPasteboard() {
        guard !text.isEmpty else { return }
        ClipboardService.shared.writeText(text)
    }
}
