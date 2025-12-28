//
//  KeyTableIndicatorView.swift
//  Geistty
//
//  Visual indicator for active key tables (vim-style modal keys).
//  Shown when a Ghostty key table is active.
//

import SwiftUI

/// Visual indicator showing when a key table is active (vim-style modal keys)
struct KeyTableIndicatorView: View {
    let tableName: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 12, weight: .medium))
            
            Text(tableName.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
        )
        .foregroundStyle(Color.accentColor)
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}

#Preview {
    KeyTableIndicatorView(tableName: "copy")
        .padding()
        .background(.black)
}
