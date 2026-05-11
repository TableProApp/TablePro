//
//  VimEngine+Macros.swift
//  TablePro
//

import Foundation

extension VimEngine {
    func handleMacroTarget(kind: VimMacroPendingKind, register: Character) {
        switch kind {
        case .recordTarget:
            macroRecording = register
            macroBuffers[register] = []
        case .replayTarget:
            let target: Character
            if register == "@" { target = lastInvokedMacro ?? Character("\0") } else { target = register }
            guard let keys = macroBuffers[target], !keys.isEmpty else {
                pendingMacroCount = 1
                return
            }
            lastInvokedMacro = target
            let count = max(1, pendingMacroCount)
            pendingMacroCount = 1
            for _ in 0..<count { replayMacro(keys: keys) }
        }
    }

    func replayMacro(keys: [(Character, Bool)]) {
        guard macroPlaybackDepth < 50 else { return }
        macroPlaybackDepth += 1
        defer { macroPlaybackDepth -= 1 }
        let saved = macroRecording
        macroRecording = nil
        for (char, shift) in keys {
            _ = process(char, shift: shift)
        }
        macroRecording = saved
    }
}
