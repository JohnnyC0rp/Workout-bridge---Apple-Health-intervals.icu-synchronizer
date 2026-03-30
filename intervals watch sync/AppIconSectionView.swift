//
//  AppIconSectionView.swift
//  intervals watch sync
//
//  Created by Codex on 27/03/2026.
//

import SwiftUI

struct AppIconSectionView: View {
    @ObservedObject var appIconManager: AppIconManager

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        Section("App Icon") {
            Text("Pick any of the 10 home-screen icon looks below. iOS changes the icon on this iPhone only, so your workouts stay put while the icon gets dramatic.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appIconManager.isUpdating {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.blue)
                    Text("Updating home-screen icon...")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.vertical, 4)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(appIconManager.options) { option in
                    Button {
                        Task {
                            await appIconManager.applyIcon(option)
                        }
                    } label: {
                        AppIconOptionCard(
                            option: option,
                            isSelected: appIconManager.selectedIconID == option.id
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(appIconManager.isUpdating)
                }
            }
            .padding(.vertical, 4)

            Text("Current icon: \(appIconManager.selectedOption.title)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !appIconManager.supportsAlternateIcons {
                Text("Alternate icons are not supported on this device, so only the primary icon will stick.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct AppIconOptionCard: View {
    let option: AppIconOption
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Image(option.previewAssetName)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? .green : .white.opacity(0.9))
                    .padding(10)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(option.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(minHeight: 30, alignment: .topLeading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isSelected ? Color.blue : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        }
        .shadow(color: .black.opacity(isSelected ? 0.14 : 0.06), radius: isSelected ? 12 : 8, y: 4)
    }
}
