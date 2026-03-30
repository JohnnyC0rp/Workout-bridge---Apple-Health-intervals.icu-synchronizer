//
//  SyncProgressOverlayView.swift
//  intervals watch sync
//
//  Created by Codex on 28/03/2026.
//

import SwiftUI

struct SyncProgressOverlayView: View {
    let title: String
    let detail: String?
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                if let fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let fraction {
                ProgressView(value: fraction)
                    .tint(.blue)
            } else {
                ProgressView()
                    .tint(.blue)
            }

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 18, y: 10)
        .padding(.horizontal, 16)
    }
}
