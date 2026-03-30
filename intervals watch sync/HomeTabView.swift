//
//  HomeTabView.swift
//  intervals watch sync
//
//  Created by Codex on 27/03/2026.
//

import SwiftUI

struct HomeTabView: View {
    @ObservedObject var appSettings: AppSettings
    @ObservedObject var healthKitManager: HealthKitManager
    @ObservedObject var workoutStore: WorkoutStore

    let apiKeyConfigured: Bool
    let motto: String
    let onShowSettings: () -> Void
    let onShowWorkouts: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    welcomeCard
                    overviewCards
                    quickActions
                    apiStatusCard
                    syncStatusCard
                    recentWorkoutsSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .refreshable {
                Task(priority: .userInitiated) {
                    await healthKitManager.refreshHomeDashboard()
                }
            }
            .background(backgroundGradient)
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onShowSettings) {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Open Settings")
                }
            }
        }
    }

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hello, runner!")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(motto)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.92))

            HStack(spacing: 12) {
                WelcomeBadge(title: "Health", value: healthKitTitle, tint: healthKitTint.opacity(0.22))
                WelcomeBadge(title: "Intervals", value: apiKeyConfigured ? "Ready" : "Needs key", tint: apiKeyConfigured ? .green.opacity(0.22) : .orange.opacity(0.22))
                WelcomeBadge(title: "Auto", value: appSettings.automaticUploadsEnabled ? "On" : "Off", tint: appSettings.automaticUploadsEnabled ? .blue.opacity(0.22) : .white.opacity(0.14))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.16, blue: 0.28),
                    Color(red: 0.17, green: 0.47, blue: 0.75),
                    Color(red: 0.24, green: 0.64, blue: 0.55)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .shadow(color: .black.opacity(0.16), radius: 22, y: 14)
    }

    private var overviewCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                HomeStatCard(title: "Stored", value: "\(workoutStore.visibleWorkouts.count)", subtitle: "Non-walk workouts on device", tint: .blue)
                HomeStatCard(title: "Pending", value: "\(pendingCount)", subtitle: "Need upload", tint: .orange)
                HomeStatCard(title: "Synced", value: "\(syncedCount)", subtitle: "Linked to Intervals", tint: .green)
            }
            .padding(.vertical, 4)
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Quick Actions", subtitle: "Shortcuts for the stuff you actually care about.")

            HStack(spacing: 12) {
                HomeActionButton(
                    title: "Force Sync",
                    subtitle: "Refresh workouts",
                    systemName: "arrow.clockwise",
                    tint: .blue
                ) {
                    Task {
                        await healthKitManager.forceSync()
                    }
                }

                HomeActionButton(
                    title: "Check API",
                    subtitle: "Ping Intervals",
                    systemName: "wave.3.right.circle.fill",
                    tint: .green
                ) {
                    Task {
                        await healthKitManager.checkIntervalsAPIStatus()
                    }
                }
            }

            HStack(spacing: 12) {
                HomeActionButton(
                    title: "Today’s Wellness",
                    subtitle: "Upload daily stats",
                    systemName: "heart.text.square.fill",
                    tint: .orange
                ) {
                    Task {
                        await healthKitManager.uploadWellnessManually(for: Date())
                    }
                }

                HomeActionButton(
                    title: "All Workouts",
                    subtitle: "Open library",
                    systemName: "list.bullet.rectangle.portrait.fill",
                    tint: .indigo
                ) {
                    onShowWorkouts()
                }
            }
        }
    }

    private var apiStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("Intervals API", subtitle: "Manual status check with a real request.")
                Spacer()
                statusDot
            }

            Text(healthKitManager.intervalsAPIStatusMessage)
                .font(.subheadline)
                .foregroundStyle(.primary)

            if let checkedAt = healthKitManager.intervalsAPIStatusCheckedAt {
                Text("Last checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    await healthKitManager.checkIntervalsAPIStatus()
                }
            } label: {
                if healthKitManager.isCheckingIntervalsAPIStatus {
                    Label("Checking...", systemImage: "dot.radiowaves.left.and.right")
                } else {
                    Label("Check Intervals API Status", systemImage: "wave.3.right.circle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(healthKitManager.isCheckingIntervalsAPIStatus)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var syncStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Sync Status", subtitle: "Workout and wellness state on this iPhone.")

            HStack(spacing: 12) {
                summaryPill(title: "Synced", value: "\(syncedCount)", tint: .green)
                summaryPill(title: "Pending", value: "\(pendingCount)", tint: .orange)
            }

            statusRow(
                title: "Workouts",
                message: healthKitManager.statusMessage,
                tint: .blue
            )

            statusRow(
                title: "Wellness",
                message: healthKitManager.lastWellnessStatusMessage,
                tint: .orange
            )

            if let lastSync = workoutStore.lastAnchoredSyncAt {
                Text("HealthKit checked \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let lastSyncError = healthKitManager.lastSyncError {
                Label(lastSyncError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                Task {
                    await healthKitManager.uploadWorkoutsManually(uuids: workoutStore.visiblePendingWorkouts.map(\.healthKitUUID))
                }
            } label: {
                if healthKitManager.isSyncing {
                    Label("Syncing Pending Workouts...", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Sync All Pending (\(pendingCount))", systemImage: "icloud.and.arrow.up.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canUploadWorkouts || pendingCount == 0 || healthKitManager.isSyncing)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var recentWorkoutsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("Recent Workouts", subtitle: "Latest sessions from Apple Health.")
                Spacer()
                Button("See All", action: onShowWorkouts)
                    .font(.subheadline.weight(.semibold))
            }

            if recentWorkouts.isEmpty {
                ContentUnavailableView(
                    "No workouts yet",
                    systemImage: "figure.run.circle",
                    description: Text("Grant Health access and sync once. Then this screen becomes much less lonely.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 12) {
                    ForEach(recentWorkouts) { workout in
                        CompactWorkoutCard(
                            workout: workout,
                            canUpload: canUploadWorkouts
                        ) {
                            Task {
                                await healthKitManager.uploadWorkoutManually(uuid: workout.healthKitUUID)
                            }
                        }
                    }
                }
            }
        }
    }

    private var recentWorkouts: [WorkoutModel] {
        Array(workoutStore.visibleWorkouts.prefix(4))
    }

    private var pendingCount: Int {
        workoutStore.visiblePendingWorkouts.count
    }

    private var syncedCount: Int {
        workoutStore.visibleSyncedWorkouts.count
    }

    private var canUploadWorkouts: Bool {
        apiKeyConfigured && healthKitManager.authorizationState == .ready
    }

    private var healthKitTitle: String {
        switch healthKitManager.authorizationState {
        case .ready:
            return "Ready"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Ask"
        case .unavailable:
            return "Off"
        }
    }

    private var healthKitTint: Color {
        switch healthKitManager.authorizationState {
        case .ready:
            return .green
        case .denied:
            return .red
        case .notDetermined:
            return .orange
        case .unavailable:
            return .gray
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(apiStatusColor)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
    }

    private var apiStatusColor: Color {
        switch healthKitManager.intervalsAPIStatusHealthy {
        case .some(true):
            return .green
        case .some(false):
            return .red
        case .none:
            return .gray
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(uiColor: .systemGroupedBackground),
                Color(red: 0.95, green: 0.98, blue: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func summaryPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func statusRow(title: String, message: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}

private struct WelcomeBadge: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.72))
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct HomeStatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 160, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct HomeActionButton: View {
    let title: String
    let subtitle: String
    let systemName: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: systemName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
