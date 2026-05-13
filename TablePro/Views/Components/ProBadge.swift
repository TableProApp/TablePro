//
//  ProBadge.swift
//  TablePro
//

import SwiftUI

struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(nsColor: .systemOrange), in: Capsule())
            .accessibilityLabel(Text("Pro feature"))
    }
}

#Preview {
    HStack {
        Text("Linked Folders")
        ProBadge()
    }
    .padding()
}
