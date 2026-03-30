//
//  WorkoutsTabView.swift
//  intervals watch sync
//
//  Created by Codex on 27/03/2026.
//

import SwiftUI

struct WorkoutsTabView: View {
    @ObservedObject var healthKitManager: HealthKitManager
    @ObservedObject var workoutStore: WorkoutStore

    let apiKeyConfigured: Bool
    let onShowSettings: () -> Void

    @State private var selectedWorkoutTypes: Set<String> = []
    @State private var workoutFilterStartDate = Date()
    @State private var workoutFilterEndDate = Date()
    @State private var didSeedWorkoutFilters = false
    @State private var workoutPendingDeletion: WorkoutModel?
    @State private var searchText = ""
    @State private var wellnessBulkStartDate = Date()
    @State private var wellnessBulkEndDate = Date()

    var body: some View {
        NavigationStack {
            List {
                workoutSummarySection
                workoutFiltersSection
                bulkUploadsSection
                workoutsSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Workouts")
            .searchable(text: $searchText, prompt: "Search workouts")
            .task {
                seedWorkoutFiltersIfNeeded()
            }
            .onChange(of: workoutStore.visibleWorkouts.map(\.healthKitUUID)) { _, _ in
                seedWorkoutFiltersIfNeeded()
            }
            .refreshable {
                Task(priority: .userInitiated) {
                    await healthKitManager.forceSync()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onShowSettings) {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete synced workout from Intervals?",
            isPresented: Binding(
                get: { workoutPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        workoutPendingDeletion = nil
                    }
                }
            ),
            presenting: workoutPendingDeletion
        ) { workout in
            Button("Delete from Intervals", role: .destructive) {
                Task {
                    await healthKitManager.deleteWorkoutFromIntervals(uuid: workout.healthKitUUID)
                }
            }
        } message: { workout in
            Text("This removes the synced \(workout.displayName) from Intervals.icu and marks it pending locally again.")
        }
    }

    private var workoutSummarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("All Workouts")
                    .font(.title2.weight(.bold))
                Text("Filter, search, bulk upload, and inspect every workout we keep from Apple Health. Walking workouts are ignored entirely.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    summaryBadge(title: "Visible", value: "\(filteredWorkouts.count)", tint: .blue)
                    summaryBadge(title: "Pending", value: "\(pendingFilteredWorkouts.count)", tint: .orange)
                    summaryBadge(title: "Synced", value: "\(filteredWorkouts.filter(\.sentToIntervals).count)", tint: .green)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Color.clear)
    }

    private var workoutFiltersSection: some View {
        Section("Filters") {
            Text("Filter by type, date range, and search text. Walking workouts are excluded at the sync layer, not just hidden here. Bulk upload uses the current filtered view, which saves you from tapping Upload until your thumb files a complaint.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !availableWorkoutTypes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChipButton(
                            title: "All",
                            isSelected: Set(availableWorkoutTypes) == selectedWorkoutTypes,
                            action: { selectedWorkoutTypes = Set(availableWorkoutTypes) }
                        )

                        ForEach(availableWorkoutTypes, id: \.self) { workoutType in
                            FilterChipButton(
                                title: workoutType,
                                isSelected: selectedWorkoutTypes.contains(workoutType),
                                action: { toggleWorkoutType(workoutType) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            DatePicker(
                "From",
                selection: $workoutFilterStartDate,
                in: ...workoutFilterEndDate,
                displayedComponents: .date
            )

            DatePicker(
                "To",
                selection: $workoutFilterEndDate,
                in: workoutFilterStartDate...Date(),
                displayedComponents: .date
            )

            Text("Showing \(filteredWorkouts.count) of \(workoutStore.visibleWorkouts.count) workout(s).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Refresh Intervals Sync Status") {
                Task {
                    await healthKitManager.refreshIntervalsStatuses()
                }
            }
            .disabled(!apiKeyConfigured || healthKitManager.isSyncing || workoutStore.visibleWorkouts.isEmpty)
        }
    }

    private var bulkUploadsSection: some View {
        Section("Bulk Uploads") {
            Text("Use the current workout filters for bulk workout upload. Wellness bulk upload has its own day range so you can backfill gaps between workouts. Bulk workout upload now prepares workouts on-device first, then uploads the prepared files.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text("Workout range presets")
                    .font(.subheadline.weight(.semibold))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        bulkPresetButton("30D") { setWorkoutRange(daysBack: 30) }
                        bulkPresetButton("90D") { setWorkoutRange(daysBack: 90) }
                        bulkPresetButton("1Y") { setWorkoutRange(daysBack: 365) }
                        bulkPresetButton("All Time") { setWorkoutRangeToAllTime() }
                    }
                    .padding(.vertical, 2)
                }
            }

            Text("Visible pending workouts eligible for bulk upload: \(pendingFilteredBulkUploadWorkouts.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Upload Visible Pending Workouts (\(pendingFilteredBulkUploadWorkouts.count))") {
                Task {
                    await healthKitManager.uploadWorkoutsManually(uuids: pendingFilteredBulkUploadWorkouts.map(\.healthKitUUID))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canUploadWorkouts || pendingFilteredBulkUploadWorkouts.isEmpty || healthKitManager.isSyncing)

            VStack(alignment: .leading, spacing: 10) {
                Text("Wellness range presets")
                    .font(.subheadline.weight(.semibold))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        bulkPresetButton("30D") { setWellnessRange(daysBack: 30) }
                        bulkPresetButton("90D") { setWellnessRange(daysBack: 90) }
                        bulkPresetButton("1Y") { setWellnessRange(daysBack: 365) }
                        bulkPresetButton("All Time") { setWellnessRangeToAllTime() }
                    }
                    .padding(.vertical, 2)
                }
            }

            DatePicker(
                "Wellness from",
                selection: $wellnessBulkStartDate,
                in: ...wellnessBulkEndDate,
                displayedComponents: .date
            )

            DatePicker(
                "Wellness to",
                selection: $wellnessBulkEndDate,
                in: wellnessBulkStartDate...Date(),
                displayedComponents: .date
            )

            Text("Selected wellness span: \(selectedWellnessDayCount) day(s)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Upload Wellness Range") {
                Task {
                    await healthKitManager.uploadWellnessRangeManually(from: wellnessBulkStartDate, to: wellnessBulkEndDate)
                }
            }
            .buttonStyle(.bordered)
            .disabled(!canUploadWorkouts || healthKitManager.isSyncing)
        }
    }

    private var workoutsSection: some View {
        Section("Results") {
            if filteredWorkouts.isEmpty {
                ContentUnavailableView(
                    workoutStore.visibleWorkouts.isEmpty ? "No workouts discovered yet" : "No workouts match the current filters",
                    systemImage: "heart.text.square",
                    description: Text(workoutStore.visibleWorkouts.isEmpty
                        ? "Grant Health access, then run Force Sync to import historical workouts and watch for new ones."
                        : "Adjust the workout types, search, or date range to widen the list.")
                )
            } else {
                ForEach(filteredWorkouts) { workout in
                    WorkoutRowView(
                        workout: workout,
                        canUpload: canUploadWorkouts,
                        canDeleteRemote: apiKeyConfigured,
                        onUpload: {
                            Task {
                                await healthKitManager.uploadWorkoutManually(uuid: workout.healthKitUUID)
                            }
                        },
                        onRefreshStreams: {
                            Task {
                                await healthKitManager.refreshWorkoutStreamDebug(uuid: workout.healthKitUUID)
                            }
                        },
                        onDelete: {
                            workoutPendingDeletion = workout
                        }
                    )
                }
            }
        }
    }

    private var canUploadWorkouts: Bool {
        apiKeyConfigured && healthKitManager.authorizationState == .ready
    }

    private var availableWorkoutTypes: [String] {
        Array(Set(workoutStore.visibleWorkouts.map(\.workoutType))).sorted()
    }

    private var filteredWorkouts: [WorkoutModel] {
        let endOfDay = Calendar.autoupdatingCurrent.date(byAdding: DateComponents(day: 1, second: -1), to: workoutFilterEndDate) ?? workoutFilterEndDate
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return workoutStore.visibleWorkouts.filter { workout in
            let matchesType = selectedWorkoutTypes.contains(workout.workoutType)
            let matchesDate = workout.startDate >= workoutFilterStartDate && workout.startDate <= endOfDay
            let matchesSearch = normalizedSearch.isEmpty || [
                workout.displayName,
                workout.workoutType,
                workout.sourceName ?? "",
                workout.deviceName ?? ""
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(normalizedSearch)

            return matchesType && matchesDate && matchesSearch
        }
    }

    private var pendingFilteredWorkouts: [WorkoutModel] {
        filteredWorkouts.filter { !$0.sentToIntervals }
    }

    private var pendingFilteredBulkUploadWorkouts: [WorkoutModel] {
        pendingFilteredWorkouts
    }

    private func seedWorkoutFiltersIfNeeded() {
        guard !didSeedWorkoutFilters, !workoutStore.visibleWorkouts.isEmpty else {
            return
        }

        let sortedWorkouts = workoutStore.visibleWorkouts.sorted { $0.startDate < $1.startDate }
        workoutFilterStartDate = Calendar.autoupdatingCurrent.startOfDay(for: sortedWorkouts.first?.startDate ?? Date())
        workoutFilterEndDate = Calendar.autoupdatingCurrent.startOfDay(for: sortedWorkouts.last?.startDate ?? Date())
        wellnessBulkStartDate = workoutFilterStartDate
        wellnessBulkEndDate = workoutFilterEndDate
        selectedWorkoutTypes = Set(sortedWorkouts.map(\.workoutType))
        didSeedWorkoutFilters = true
    }

    private func toggleWorkoutType(_ workoutType: String) {
        if selectedWorkoutTypes.contains(workoutType) {
            selectedWorkoutTypes.remove(workoutType)
        } else {
            selectedWorkoutTypes.insert(workoutType)
        }
    }

    private func summaryBadge(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var selectedWellnessDayCount: Int {
        let calendar = Calendar.autoupdatingCurrent
        let from = calendar.startOfDay(for: min(wellnessBulkStartDate, wellnessBulkEndDate))
        let to = calendar.startOfDay(for: max(wellnessBulkStartDate, wellnessBulkEndDate))
        return (calendar.dateComponents([.day], from: from, to: to).day ?? 0) + 1
    }

    private func bulkPresetButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func setWorkoutRange(daysBack: Int) {
        let calendar = Calendar.autoupdatingCurrent
        let end = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -max(daysBack - 1, 0), to: end) ?? end
        workoutFilterStartDate = max(start, earliestWorkoutDay ?? start)
        workoutFilterEndDate = end
    }

    private func setWellnessRange(daysBack: Int) {
        let calendar = Calendar.autoupdatingCurrent
        let end = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -max(daysBack - 1, 0), to: end) ?? end
        wellnessBulkStartDate = max(start, earliestWorkoutDay ?? start)
        wellnessBulkEndDate = end
    }

    private func setWorkoutRangeToAllTime() {
        workoutFilterStartDate = earliestWorkoutDay ?? Date()
        workoutFilterEndDate = latestWorkoutDay ?? Date()
    }

    private func setWellnessRangeToAllTime() {
        wellnessBulkStartDate = earliestWorkoutDay ?? Date()
        wellnessBulkEndDate = latestWorkoutDay ?? Date()
    }

    private var earliestWorkoutDay: Date? {
        workoutStore.visibleWorkouts.map(\.startDate).min().map { Calendar.autoupdatingCurrent.startOfDay(for: $0) }
    }

    private var latestWorkoutDay: Date? {
        workoutStore.visibleWorkouts.map(\.startDate).max().map { Calendar.autoupdatingCurrent.startOfDay(for: $0) }
    }
}
