//
//  AppIconManager.swift
//  intervals watch sync
//
//  Created by Codex on 27/03/2026.
//

import Combine
import SwiftUI
import UIKit

struct AppIconOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let previewAssetName: String
    let alternateIconName: String?
}

@MainActor
final class AppIconManager: ObservableObject {
    @Published private(set) var selectedIconID: String
    @Published private(set) var isUpdating = false
    @Published private(set) var requestBanner: RequestStatusBanner?

    let options: [AppIconOption]

    private var bannerDismissTask: Task<Void, Never>?

    init() {
        self.options = [
            AppIconOption(
                id: "AppIcon",
                title: "Bridge Pulse",
                subtitle: "Cyan bridge pulse",
                previewAssetName: "IconPreviewBridgePulse",
                alternateIconName: nil
            ),
            AppIconOption(
                id: "AppIconSummitTrack",
                title: "Summit Track",
                subtitle: "Warm mountain route",
                previewAssetName: "IconPreviewSummitTrack",
                alternateIconName: "AppIconSummitTrack"
            ),
            AppIconOption(
                id: "AppIconOrbitRing",
                title: "Orbit Ring",
                subtitle: "Navy orbital rings",
                previewAssetName: "IconPreviewOrbitRing",
                alternateIconName: "AppIconOrbitRing"
            ),
            AppIconOption(
                id: "AppIconWaveTempo",
                title: "Wave Tempo",
                subtitle: "Surf tempo stripes",
                previewAssetName: "IconPreviewWaveTempo",
                alternateIconName: "AppIconWaveTempo"
            ),
            AppIconOption(
                id: "AppIconHorizonPath",
                title: "Horizon Path",
                subtitle: "Skyline winding path",
                previewAssetName: "IconPreviewHorizonPath",
                alternateIconName: "AppIconHorizonPath"
            ),
            AppIconOption(
                id: "AppIconSignalCrest",
                title: "Signal Crest",
                subtitle: "Dark neon signal",
                previewAssetName: "IconPreviewSignalCrest",
                alternateIconName: "AppIconSignalCrest"
            ),
            AppIconOption(
                id: "AppIconSplitMarker",
                title: "Split Marker",
                subtitle: "Fast split lane",
                previewAssetName: "IconPreviewSplitMarker",
                alternateIconName: "AppIconSplitMarker"
            ),
            AppIconOption(
                id: "AppIconTrailGrid",
                title: "Trail Grid",
                subtitle: "Top trail map",
                previewAssetName: "IconPreviewTrailGrid",
                alternateIconName: "AppIconTrailGrid"
            ),
            AppIconOption(
                id: "AppIconCompassBurn",
                title: "Compass Burn",
                subtitle: "Amber compass arrow",
                previewAssetName: "IconPreviewCompassBurn",
                alternateIconName: "AppIconCompassBurn"
            ),
            AppIconOption(
                id: "AppIconNeonLoop",
                title: "Neon Loop",
                subtitle: "Electric endurance loop",
                previewAssetName: "IconPreviewNeonLoop",
                alternateIconName: "AppIconNeonLoop"
            )
        ]
        self.selectedIconID = "AppIcon"
    }

    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    var selectedOption: AppIconOption {
        options.first(where: { $0.id == selectedIconID }) ?? options[0]
    }

    func refreshSelection() {
        selectedIconID = Self.selectedIconID(for: UIApplication.shared.alternateIconName)
    }

    func applyIcon(_ option: AppIconOption) async {
        if option.id == selectedIconID {
            showRequestBanner(message: "Already using \(option.title).", style: .info)
            return
        }

        guard supportsAlternateIcons || option.alternateIconName == nil else {
            showRequestBanner(message: "This device does not support alternate app icons.", style: .error)
            return
        }

        isUpdating = true

        do {
            // Let iOS do the wardrobe change; we just ask politely.
            try await UIApplication.shared.setAlternateIconName(option.alternateIconName)
            refreshSelection()
            showRequestBanner(message: "Icon switched to \(option.title).", style: .success)
        } catch {
            showRequestBanner(message: error.localizedDescription, style: .error)
        }

        isUpdating = false
    }

    private func showRequestBanner(message: String, style: RequestStatusBanner.Style) {
        bannerDismissTask?.cancel()
        requestBanner = RequestStatusBanner(message: message, style: style)

        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.requestBanner = nil
        }
    }

    private static func selectedIconID(for alternateIconName: String?) -> String {
        alternateIconName ?? "AppIcon"
    }
}
