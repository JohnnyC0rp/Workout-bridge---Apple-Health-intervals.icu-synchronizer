//
//  RequestStatusBanner.swift
//  intervals watch sync
//
//  Created by Codex on 27/03/2026.
//

import SwiftUI

struct RequestStatusBanner: Identifiable, Equatable {
    enum Style: Equatable {
        case info
        case success
        case error
    }

    let id = UUID()
    let message: String
    let style: Style
}

struct AppAlertMessage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

struct RequestStatusBannerView: View {
    let banner: RequestStatusBanner

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.subheadline.weight(.semibold))

            Text(banner.message)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(backgroundColor, in: Capsule())
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var iconName: String {
        switch banner.style {
        case .info:
            return "arrow.triangle.2.circlepath"
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    private var backgroundColor: Color {
        switch banner.style {
        case .info:
            return .blue
        case .success:
            return .green
        case .error:
            return .red
        }
    }
}
