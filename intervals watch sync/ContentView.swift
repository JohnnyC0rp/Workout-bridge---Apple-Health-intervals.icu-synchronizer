//
//  ContentView.swift
//  intervals watch sync
//
//  Created by Codex on 24/03/2026.
//

import SwiftUI

private enum AppTab: Hashable {
    case home
    case workouts
    case logs
}

struct ContentView: View {
    @ObservedObject var appSettings: AppSettings
    @ObservedObject var appIconManager: AppIconManager
    @ObservedObject var healthKitManager: HealthKitManager
    @ObservedObject var workoutStore: WorkoutStore
    @ObservedObject var intervalsLogStore: IntervalsLogStore

    @State private var selectedTab: AppTab = .home
    @State private var isShowingSettings = false
    @State private var apiKeyConfigured = IntervalsConfiguration.isConfigured
    @State private var homeMotto = Self.mottos.randomElement() ?? "Train quietly. Sync loudly."
    @State private var didScheduleStartupPreparation = false
    @State private var didScheduleStartupRefresh = false

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selectedTab) {
                HomeTabView(
                    appSettings: appSettings,
                    healthKitManager: healthKitManager,
                    workoutStore: workoutStore,
                    apiKeyConfigured: apiKeyConfigured,
                    motto: homeMotto,
                    onShowSettings: { isShowingSettings = true },
                    onShowWorkouts: { selectedTab = .workouts }
                )
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(AppTab.home)

                WorkoutsTabView(
                    healthKitManager: healthKitManager,
                    workoutStore: workoutStore,
                    apiKeyConfigured: apiKeyConfigured,
                    onShowSettings: { isShowingSettings = true }
                )
                .tabItem {
                    Label("Workouts", systemImage: "figure.run")
                }
                .tag(AppTab.workouts)

                LogsTabView(
                    healthKitManager: healthKitManager,
                    intervalsLogStore: intervalsLogStore,
                    onShowSettings: { isShowingSettings = true }
                )
                .tabItem {
                    Label("Logs", systemImage: "text.alignleft")
                }
                .tag(AppTab.logs)
            }
            .task {
                refreshConfigurationState()
                appIconManager.refreshSelection()
                scheduleStartupPreparationIfNeeded()
                scheduleStartupHomeRefreshIfNeeded()
            }

            VStack(spacing: 8) {
                if let progressTitle = healthKitManager.syncProgressLabel {
                    SyncProgressOverlayView(
                        title: progressTitle,
                        detail: healthKitManager.syncProgressDetail,
                        fraction: healthKitManager.syncProgressFraction
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                ForEach(requestBanners) { banner in
                    RequestStatusBannerView(banner: banner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .zIndex(1)
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: requestBannerIDs)
        .alert(item: launchAlertBinding) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $isShowingSettings, onDismiss: refreshConfigurationState) {
            SettingsView(
                appSettings: appSettings,
                appIconManager: appIconManager,
                healthKitManager: healthKitManager,
                apiKeyConfigured: $apiKeyConfigured
            )
        }
    }

    private var requestBanners: [RequestStatusBanner] {
        [healthKitManager.requestBanner, appIconManager.requestBanner].compactMap { $0 }
    }

    private var requestBannerIDs: [UUID] {
        requestBanners.map(\.id)
    }

    private var launchAlertBinding: Binding<AppAlertMessage?> {
        Binding(
            get: { healthKitManager.activeAlert },
            set: { _ in healthKitManager.dismissActiveAlert() }
        )
    }

    private func refreshConfigurationState() {
        apiKeyConfigured = IntervalsConfiguration.isConfigured
    }

    private func scheduleStartupPreparationIfNeeded() {
        guard !didScheduleStartupPreparation else {
            return
        }

        didScheduleStartupPreparation = true

        Task(priority: .utility) {
            await workoutStore.loadIfNeeded()
            await intervalsLogStore.loadIfNeeded()
        }
    }

    private func scheduleStartupHomeRefreshIfNeeded() {
        guard !didScheduleStartupRefresh else {
            return
        }

        didScheduleStartupRefresh = true

        Task(priority: .userInitiated) {
            await healthKitManager.start()
            await healthKitManager.requestAuthorizationIfNeededOnFirstLaunch()

            // This intentionally mirrors the manual pull-to-refresh path.
            try? await Task.sleep(nanoseconds: 350_000_000)
            await healthKitManager.refreshHomeDashboard()
        }
    }

    private static let mottos = [
        "Train quietly. Sync loudly.",
        "Turn effort into evidence.",
        "Every lap deserves a paper trail.",
        "Miles in motion, data in order.",
        "Run first. Nerd out later.",
        "Strong legs, tidy metrics.",
        "Your watch worked hard. Let the app keep up.",
        "Sweat now, analyze later.",
        "Every heartbeat tells a story.",
        "Good runs fade. Good data doesn’t.",
        "Less tapping. More training.",
        "From Apple Health to actual insight."
    ]
}

#Preview {
    let settings = AppSettings()
    let store = WorkoutStore()
    let logStore = IntervalsLogStore()
    let manager = HealthKitManager(
        workoutStore: store,
        apiClient: IntervalsApiClient(logger: logStore),
        settings: settings
    )
    ContentView(
        appSettings: settings,
        appIconManager: AppIconManager(),
        healthKitManager: manager,
        workoutStore: store,
        intervalsLogStore: logStore
    )
}
