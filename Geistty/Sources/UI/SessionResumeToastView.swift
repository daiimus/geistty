//
//  SessionResumeToastView.swift
//  Geistty
//
//  Transient toast shown when a tmux session is connected,
//  indicating whether the session was newly created or resumed.
//

import SwiftUI

/// Toast indicator showing tmux session resume status
struct SessionResumeToastView: View {
    let status: SessionResumeStatus
    
    private var icon: String {
        switch status {
        case .created: return "plus.circle"
        case .resumed: return "arrow.uturn.forward.circle"
        }
    }
    
    private var label: String {
        switch status {
        case .created(let name): return "Created '\(name)'"
        case .resumed(let name): return "Resumed '\(name)'"
        }
    }
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.green.opacity(0.5), lineWidth: 1)
                )
        )
        .foregroundStyle(Color.green)
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}

#Preview {
    VStack(spacing: 12) {
        SessionResumeToastView(status: .resumed(name: "main"))
        SessionResumeToastView(status: .created(name: "main"))
    }
    .padding()
    .background(.black)
}
