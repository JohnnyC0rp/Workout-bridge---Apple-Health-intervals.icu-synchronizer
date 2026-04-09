//
//  HealthKitManager.swift
//  intervals watch sync
//
//  Created by Codex on 24/03/2026.
//

import Combine
import CoreLocation
import Foundation
import HealthKit

@MainActor
final class HealthKitManager: ObservableObject {
    enum AuthorizationState: String {
        case unavailable
        case notDetermined
        case ready
        case denied

        var title: String {
            switch self {
            case .unavailable:
                return "HealthKit unavailable"
            case .notDetermined:
                return "Health access not granted"
            case .ready:
                return "Health access ready"
            case .denied:
                return "Health access denied"
            }
        }
    }

    enum ManagerError: LocalizedError {
        case workoutNotFound(UUID)
        case noWellnessData(Date)
        case walkingWorkoutsIgnored

        var errorDescription: String? {
            switch self {
            case .workoutNotFound(let uuid):
                return "Could not find the HealthKit workout \(uuid.uuidString)."
            case .noWellnessData(let date):
                return "No wellness data was found for \(date.formatted(date: .abbreviated, time: .omitted))."
            case .walkingWorkoutsIgnored:
                return "Walking workouts are ignored and will not be uploaded to Intervals."
            }
        }
    }

    private struct SamplePoint: Sendable {
        let date: Date
        let value: Double
    }

    private struct RoutePoint: Sendable {
        let date: Date
        let latitude: Double
        let longitude: Double
        let altitude: Double?
        let speed: Double?
        let cumulativeDistance: Double
    }

    private struct ExtraStreamInspection: Sendable {
        let requested: [String]
        let accepted: [String]
        let available: [String]
    }

    private struct PlannedEventMatch: Sendable {
        let id: Int
        let candidateCount: Int
        let bestDurationPenalty: Int
        let runnerUpDurationPenalty: Int?
    }

    private struct WeightedSleepInterval: Sendable {
        let interval: DateInterval
        let stageWeight: Double
    }

    private struct WeightedHeartRateSegment: Sendable {
        let interval: DateInterval
        let heartRate: Double
        let stageWeight: Double
    }

    private struct SleepSummary: Sendable {
        let asleepIntervals: [DateInterval]
        let weightedAsleepIntervals: [WeightedSleepInterval]
        let sleepSeconds: Double
        let inBedSeconds: Double
        let awakeSeconds: Double
        let remSeconds: Double
        let deepSeconds: Double
        let coreSeconds: Double
        let unspecifiedAsleepSeconds: Double

        var hasStageDetail: Bool {
            inBedSeconds > 0 ||
            awakeSeconds > 0 ||
            remSeconds > 0 ||
            deepSeconds > 0 ||
            coreSeconds > 0 ||
            unspecifiedAsleepSeconds > 0
        }

        static let empty = SleepSummary(
            asleepIntervals: [],
            weightedAsleepIntervals: [],
            sleepSeconds: 0,
            inBedSeconds: 0,
            awakeSeconds: 0,
            remSeconds: 0,
            deepSeconds: 0,
            coreSeconds: 0,
            unspecifiedAsleepSeconds: 0
        )
    }

    private struct WellnessUploadSummary: Sendable {
        var uploadedDays = 0
        var skippedDays = 0
    }

    private struct PreparedWorkoutUpload: Sendable {
        let workout: WorkoutModel
        let fileURL: URL
    }

    private struct PostUploadSyncIssue {
        let userMessage: String
        let logMessage: String
    }

    private struct SeriesCursor: Sendable {
        enum Mode {
            case latest
            case cumulative
        }

        private(set) var index = 0
        private(set) var latest: Double?
        private(set) var runningTotal = 0.0

        let points: [SamplePoint]
        let mode: Mode

        mutating func advance(to date: Date) {
            while index < points.count, points[index].date <= date {
                switch mode {
                case .latest:
                    latest = points[index].value
                case .cumulative:
                    runningTotal += points[index].value
                    latest = runningTotal
                }

                index += 1
            }
        }

        var currentValue: Double? {
            latest
        }
    }

    @Published private(set) var authorizationState: AuthorizationState = .notDetermined
    @Published private(set) var statusMessage = "Waiting for HealthKit authorization."
    @Published private(set) var isSyncing = false
    @Published private(set) var backgroundDeliveryEnabled = false
    @Published private(set) var lastSyncError: String?
    @Published private(set) var syncProgressFraction: Double?
    @Published private(set) var syncProgressLabel: String?
    @Published private(set) var syncProgressDetail: String?
    @Published private(set) var lastWellnessStatusMessage = "Wellness uploads run automatically after workout syncs."
    @Published private(set) var requestBanner: RequestStatusBanner?
    @Published private(set) var activeAlert: AppAlertMessage?
    @Published private(set) var intervalsAPIStatusMessage = "Tap Check API Status to verify Intervals."
    @Published private(set) var intervalsAPIStatusHealthy: Bool?
    @Published private(set) var intervalsAPIStatusCheckedAt: Date?
    @Published private(set) var isCheckingIntervalsAPIStatus = false

    private let healthStore: HKHealthStore
    private let workoutStore: WorkoutStore
    private let apiClient: IntervalsApiClient
    private let settings: AppSettings
    private let fileManager: FileManager
    private let exportDirectory: URL

    private var observerQuery: HKObserverQuery?
    private var hasPromptedForAuthorizationThisLaunch = false
    private var hasCheckedIntervalsAPIStatusThisLaunch = false
    private var bannerDismissTask: Task<Void, Never>?
    private var dashboardRefreshTask: Task<Void, Never>?
    private var hasCompletedLaunchMaintenance = false
    private var hasStarted = false
    private var preserveNextWellnessStatusSummary = false

    private let launchWellnessRecentDays = 3
    private let walkingCleanupLookbackDays = 3650

    init(
        healthStore: HKHealthStore = HKHealthStore(),
        workoutStore: WorkoutStore,
        apiClient: IntervalsApiClient,
        settings: AppSettings,
        fileManager: FileManager = .default
    ) {
        self.healthStore = healthStore
        self.workoutStore = workoutStore
        self.apiClient = apiClient
        self.settings = settings
        self.fileManager = fileManager

        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.exportDirectory = supportDirectory
            .appendingPathComponent("WorkoutBridge", isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)

    }

    func start() async {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        await bootstrap()
    }

    func requestAuthorizationIfNeededOnFirstLaunch() async {
        guard !hasPromptedForAuthorizationThisLaunch else {
            return
        }

        hasPromptedForAuthorizationThisLaunch = true

        if authorizationState == .notDetermined {
            await requestAuthorization()
        }
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationState = .unavailable
            statusMessage = "HealthKit is not available on this device."
            return
        }

        do {
            try await healthStoreRequestAuthorization()
            authorizationState = .ready
            statusMessage = "HealthKit access granted. Observer queries armed."
            try await configureBackgroundDelivery()
            startWorkoutObserverIfNeeded()
            await syncWorkouts(reason: "authorization")
        } catch {
            authorizationState = .denied
            statusMessage = "HealthKit authorization failed."
            lastSyncError = error.localizedDescription
        }
    }

    func forceSync(reason: String = "manual") async {
        await syncWorkouts(reason: reason)
    }

    func refreshHomeDashboard(reason: String = "manual") async {
        if let dashboardRefreshTask {
            await dashboardRefreshTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer {
                self.dashboardRefreshTask = nil
            }

            if IntervalsConfiguration.isConfigured {
                await self.checkIntervalsAPIStatus()
            }

            if self.authorizationState == .ready {
                await self.forceSync(reason: self.dashboardSyncReason(for: reason))
            }

            self.refreshWellnessStatusSummary()
        }

        dashboardRefreshTask = task
        await task.value
    }

    private func dashboardSyncReason(for requestedReason: String) -> String {
        // Preserve launch-only maintenance for the first startup refresh.
        // Otherwise the app acts surprised that "launch" means launch. Rude.
        requestedReason == "launch" && !hasCompletedLaunchMaintenance
            ? "launch"
            : "manual"
    }

    func checkIntervalsAPIStatusOnLaunchIfNeeded() async {
        guard IntervalsConfiguration.isConfigured, !hasCheckedIntervalsAPIStatusThisLaunch else {
            return
        }

        hasCheckedIntervalsAPIStatusThisLaunch = true
        await checkIntervalsAPIStatus()
    }

    func dismissActiveAlert() {
        activeAlert = nil
    }

    func uploadWorkoutManually(uuid: UUID) async {
        guard !isSyncing else { return }

        isSyncing = true
        lastSyncError = nil
        statusMessage = "Uploading workout..."
        setProgress(label: "Preparing workout upload...", fraction: 0.1)

        defer {
            isSyncing = false
            clearProgress()
        }

        do {
            let uploadedWorkout = try await performWorkoutUpload(uuid: uuid)
            statusMessage = "Synced \(uploadedWorkout.displayName)."
            showRequestBanner(message: "Synced \(uploadedWorkout.displayName) to Intervals.", style: .success)
        } catch {
            workoutStore.markUploadFailed(for: uuid, error: error.localizedDescription)
            lastSyncError = error.localizedDescription
            statusMessage = "Workout upload failed."
            showRequestBanner(message: error.localizedDescription, style: .error)
        }
    }

    func uploadWorkoutsManually(uuids: [UUID]) async {
        guard authorizationState == .ready else {
            lastSyncError = "Grant HealthKit access before uploading workouts."
            statusMessage = "HealthKit authorization required."
            showRequestBanner(message: "Grant Health access before bulk upload.", style: .error)
            return
        }

        var seenUUIDs = Set<UUID>()
        let uniqueUUIDs = uuids.reduce(into: [UUID]()) { partialResult, uuid in
            if seenUUIDs.insert(uuid).inserted {
                partialResult.append(uuid)
            }
        }
        .sorted {
            let leftDate = workoutStore.workout(with: $0)?.startDate ?? .distantPast
            let rightDate = workoutStore.workout(with: $1)?.startDate ?? .distantPast
            return leftDate < rightDate
        }
        guard !uniqueUUIDs.isEmpty else {
            showRequestBanner(message: "No workouts matched the current filters.", style: .info)
            return
        }

        let bulkEligibleUUIDs = uniqueUUIDs.filter { !shouldSkipBulkWorkoutUpload(uuid: $0) }
        let skippedWalkCount = uniqueUUIDs.count - bulkEligibleUUIDs.count

        guard !bulkEligibleUUIDs.isEmpty else {
            showRequestBanner(message: "Walking workouts are ignored completely, and no other workouts matched the filters.", style: .info)
            return
        }

        guard !isSyncing else { return }

        isSyncing = true
        lastSyncError = nil
        statusMessage = "Preparing selected workouts..."
        showRequestBanner(
            message: skippedWalkCount > 0
                ? "Preparing \(bulkEligibleUUIDs.count) workout(s). Skipping \(skippedWalkCount) walk(s)."
                : "Preparing \(bulkEligibleUUIDs.count) workout(s) for bulk upload...",
            style: .info
        )

        var preparedUploads: [PreparedWorkoutUpload] = []
        var uploadedWorkoutDates: [Date] = []
        var preparedCount = 0
        var succeeded = 0
        var failed = 0

        defer {
            isSyncing = false
            clearProgress()
        }

        for (index, uuid) in bulkEligibleUUIDs.enumerated() {
            let buildFraction = 0.05 + (Double(index) / Double(max(bulkEligibleUUIDs.count, 1))) * 0.4
            let exportFraction = min(buildFraction + 0.04, 0.48)

            setProgress(
                label: "Preparing workout \(index + 1) of \(bulkEligibleUUIDs.count)...",
                fraction: buildFraction,
                detail: "Prepared \(preparedCount) • Failed \(failed) • Remaining \(max(bulkEligibleUUIDs.count - index, 0))"
            )

            do {
                let prepared = try await prepareWorkoutUpload(
                    uuid: uuid,
                    buildLabel: "Building workout \(index + 1) of \(bulkEligibleUUIDs.count)...",
                    buildFraction: buildFraction,
                    exportLabel: "Exporting workout \(index + 1) of \(bulkEligibleUUIDs.count)...",
                    exportFraction: exportFraction
                )
                preparedUploads.append(prepared)
                preparedCount += 1
            } catch {
                workoutStore.markUploadFailed(for: uuid, error: error.localizedDescription)
                lastSyncError = error.localizedDescription
                failed += 1
            }

            if index.isMultiple(of: 4) {
                await Task.yield()
            }
        }

        for (index, prepared) in preparedUploads.enumerated() {
            let uploadFraction = 0.55 + (Double(index) / Double(max(preparedUploads.count, 1))) * 0.3
            let streamsFraction = min(uploadFraction + 0.08, 0.9)

            do {
                let uploadedWorkout = try await uploadPreparedWorkout(
                    prepared,
                    uploadLabel: "Uploading workout \(index + 1) of \(preparedUploads.count)...",
                    uploadFraction: uploadFraction,
                    extraStreamsLabel: "Syncing workout streams \(index + 1) of \(preparedUploads.count)...",
                    extraStreamsFraction: streamsFraction,
                    shouldUploadWellness: false
                )
                uploadedWorkoutDates.append(uploadedWorkout.startDate)
                succeeded += 1
            } catch {
                workoutStore.markUploadFailed(for: prepared.workout.healthKitUUID, error: error.localizedDescription)
                lastSyncError = error.localizedDescription
                failed += 1
            }

            if index.isMultiple(of: 2) {
                await Task.yield()
            }
        }

        var wellnessSummaryMessage: String?
        if let earliestUploadedWorkout = uploadedWorkoutDates.min(),
           let latestUploadedWorkout = uploadedWorkoutDates.max() {
            do {
                setProgress(
                    label: "Backfilling wellness for uploaded workout days...",
                    fraction: 0.95,
                    detail: "Covering \(Self.localDayFormatter.string(from: earliestUploadedWorkout)) to \(Self.localDayFormatter.string(from: latestUploadedWorkout))"
                )
                let summary = try await uploadWellnessRange(from: earliestUploadedWorkout, to: latestUploadedWorkout, force: false)
                if summary.uploadedDays > 0 {
                    wellnessSummaryMessage = "Wellness uploaded for \(summary.uploadedDays) day(s)."
                    lastWellnessStatusMessage = "Uploaded wellness for \(summary.uploadedDays) day(s) during bulk workout upload."
                    refreshWellnessStatusSummary()
                }
            } catch {
                lastSyncError = error.localizedDescription
                wellnessSummaryMessage = "Wellness backfill failed."
            }
        }

        setProgress(
            label: "Finishing bulk workout upload...",
            fraction: 1,
            detail: "Prepared \(preparedCount) • Succeeded \(succeeded) • Failed \(failed)"
        )

        statusMessage = failed == 0
            ? "Synced \(succeeded) workout(s)."
            : "Synced \(succeeded) workout(s), \(failed) failed."
        showRequestBanner(
            message: {
                let base = failed == 0
                    ? "Synced \(succeeded) filtered workout(s)."
                    : "Synced \(succeeded), failed \(failed) filtered workout(s)."
                if let wellnessSummaryMessage {
                    return "\(base) \(wellnessSummaryMessage)"
                }
                return base
            }(),
            style: failed == 0 ? .success : .error
        )
    }

    func refreshIntervalsStatuses() async {
        guard IntervalsConfiguration.isConfigured else {
            let message = "Save your Intervals API key before refreshing sync status."
            lastSyncError = message
            statusMessage = message
            showRequestBanner(message: message, style: .error)
            return
        }

        guard !isSyncing else { return }

        isSyncing = true
        lastSyncError = nil
        statusMessage = "Refreshing Intervals sync status..."
        setProgress(label: "Checking Intervals activities...", fraction: 0.2)

        defer {
            isSyncing = false
            clearProgress()
        }

        do {
            let matchedCount = try await reconcileStoredWorkoutsWithIntervals()
            statusMessage = "Matched \(matchedCount) synced workout(s) on Intervals."
            showRequestBanner(message: "Refreshed Intervals status for \(matchedCount) workout(s).", style: .success)
        } catch {
            lastSyncError = error.localizedDescription
            statusMessage = "Intervals status refresh failed."
            showRequestBanner(message: error.localizedDescription, style: .error)
        }
    }

    func checkIntervalsAPIStatus() async {
        guard IntervalsConfiguration.isConfigured else {
            let message = "Save your Intervals API key before checking Intervals."
            lastSyncError = message
            intervalsAPIStatusMessage = message
            intervalsAPIStatusHealthy = false
            showRequestBanner(message: message, style: .error)
            return
        }

        guard !isCheckingIntervalsAPIStatus else {
            return
        }

        isCheckingIntervalsAPIStatus = true
        intervalsAPIStatusMessage = "Checking Intervals API..."

        defer {
            isCheckingIntervalsAPIStatus = false
        }

        do {
            let snapshot = try await apiClient.checkAPIStatus()
            intervalsAPIStatusHealthy = true
            intervalsAPIStatusCheckedAt = snapshot.checkedAt
            intervalsAPIStatusMessage = "Intervals API is online in \(snapshot.latencyMilliseconds) ms for athlete \(snapshot.athleteID)."
            showRequestBanner(message: "Intervals API responded in \(snapshot.latencyMilliseconds) ms.", style: .success)
        } catch {
            if Self.isCancellation(error) {
                return
            }

            lastSyncError = error.localizedDescription
            intervalsAPIStatusHealthy = false
            intervalsAPIStatusCheckedAt = Date()
            intervalsAPIStatusMessage = error.localizedDescription
            showRequestBanner(message: error.localizedDescription, style: .error)
        }
    }

    func refreshWorkoutStreamDebug(uuid: UUID) async {
        guard IntervalsConfiguration.isConfigured else {
            let message = "Save your Intervals API key before inspecting workout streams."
            lastSyncError = message
            showRequestBanner(message: message, style: .error)
            return
        }

        guard !isSyncing else { return }

        guard let workout = workoutStore.workout(with: uuid),
              let activityID = workout.intervalsActivityID else {
            let message = "This workout is not linked to a synced Intervals activity yet."
            lastSyncError = message
            showRequestBanner(message: message, style: .error)
            return
        }

        isSyncing = true
        lastSyncError = nil
        statusMessage = "Inspecting workout streams on Intervals..."
        setProgress(label: "Refreshing stream debug for \(workout.displayName)...", fraction: 0.35)

        defer {
            isSyncing = false
            clearProgress()
        }

        do {
            let inspection = try await inspectRemoteExtraStreams(for: workout, activityID: activityID)
            workoutStore.updateIntervalsStreamDebug(
                for: uuid,
                requested: inspection.requested,
                accepted: inspection.accepted,
                available: inspection.available,
                error: nil
            )
            statusMessage = "Updated stream debug for \(workout.displayName)."
            showRequestBanner(message: "Updated stream debug for \(workout.displayName).", style: .success)
        } catch {
            workoutStore.updateIntervalsStreamDebug(
                for: uuid,
                requested: requestedExtraStreamTypes(for: workout),
                accepted: [],
                available: [],
                error: error.localizedDescription
            )
            lastSyncError = error.localizedDescription
            statusMessage = "Intervals stream inspection failed."
            showRequestBanner(message: error.localizedDescription, style: .error)
        }
    }

    func deleteWorkoutFromIntervals(uuid: UUID) async {
        guard IntervalsConfiguration.isConfigured else {
            let message = "Save your Intervals API key before deleting workouts."
            lastSyncError = message
            showRequestBanner(message: message, style: .error)
            return
        }

        guard !isSyncing else { return }

        guard let storedWorkout = workoutStore.workout(with: uuid),
              let activityID = storedWorkout.intervalsActivityID else {
            let message = "This workout is not linked to a known Intervals activity yet."
            lastSyncError = message
            showRequestBanner(message: message, style: .error)
            return
        }

        isSyncing = true
        lastSyncError = nil
        statusMessage = "Deleting synced workout from Intervals..."
        setProgress(label: "Deleting \(storedWorkout.displayName) from Intervals...", fraction: 0.3)

        defer {
            isSyncing = false
            clearProgress()
        }

        do {
            try await apiClient.deleteActivity(activityID: activityID)
            workoutStore.markDeletedFromIntervals(for: uuid)
            statusMessage = "Deleted \(storedWorkout.displayName) from Intervals."
            showRequestBanner(message: "Deleted \(storedWorkout.displayName) from Intervals.", style: .success)
        } catch {
            lastSyncError = error.localizedDescription
            statusMessage = "Intervals delete failed."
            showRequestBanner(message: error.localizedDescription, style: .error)
        }
    }

    func uploadWellnessManually(for date: Date) async {
        guard authorizationState == .ready else {
            lastSyncError = "Grant HealthKit access before uploading wellness."
            statusMessage = "HealthKit authorization required."
            return
        }

        guard !isSyncing else {
            return
        }

        isSyncing = true
        lastSyncError = nil
        statusMessage = "Uploading wellness..."
        setProgress(label: "Collecting wellness data...", fraction: 0.2)

        defer {
            isSyncing = false
            clearProgress()
        }

        do {
            try await uploadWellness(for: date, force: true)
            let dayID = Self.localDayFormatter.string(from: date)
            lastWellnessStatusMessage = "Uploaded wellness for \(dayID)."
            statusMessage = "Wellness uploaded."
            showRequestBanner(message: "Uploaded wellness for \(dayID).", style: .success)
            if preserveNextWellnessStatusSummary {
                preserveNextWellnessStatusSummary = false
            } else {
                refreshWellnessStatusSummary()
            }
        } catch {
            lastWellnessStatusMessage = error.localizedDescription
            lastSyncError = error.localizedDescription
            statusMessage = "Wellness upload failed."
            showRequestBanner(message: error.localizedDescription, style: .error)
        }
    }

    func uploadWellnessRangeManually(from startDate: Date, to endDate: Date) async {
        guard authorizationState == .ready else {
            lastSyncError = "Grant HealthKit access before uploading wellness."
            statusMessage = "HealthKit authorization required."
            return
        }

        guard !isSyncing else {
            return
        }

        isSyncing = true
        lastSyncError = nil
        statusMessage = "Uploading wellness range..."
        setProgress(label: "Preparing wellness range...", fraction: 0.15)
        let selectedDayCount = normalizedDayRange(from: startDate, to: endDate).count
        showRequestBanner(message: "Preparing wellness upload for \(selectedDayCount) day(s)...", style: .info)

        defer {
            isSyncing = false
            clearProgress()
        }

        do {
            let summary = try await uploadWellnessRange(from: startDate, to: endDate, force: true)
            let message = "Uploaded \(summary.uploadedDays) wellness day(s). Skipped \(summary.skippedDays) empty or unavailable day(s)."
            lastWellnessStatusMessage = message
            statusMessage = "Wellness range uploaded."
            showRequestBanner(message: message, style: .success)
            if preserveNextWellnessStatusSummary {
                preserveNextWellnessStatusSummary = false
            } else {
                refreshWellnessStatusSummary()
            }
        } catch {
            lastWellnessStatusMessage = error.localizedDescription
            lastSyncError = error.localizedDescription
            statusMessage = "Wellness range upload failed."
            showRequestBanner(message: error.localizedDescription, style: .error)
        }
    }

    private func bootstrap() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationState = .unavailable
            statusMessage = "HealthKit is not available on this device."
            return
        }

        do {
            let requestStatus = try await healthStoreRequestStatus()
            switch requestStatus {
            case .shouldRequest:
                authorizationState = .notDetermined
                statusMessage = "Authorize Apple Health access to start syncing workouts."
            case .unnecessary:
                authorizationState = .ready
                statusMessage = "Ready. Pull to refresh or wait for startup refresh."
                try await configureBackgroundDelivery()
                startWorkoutObserverIfNeeded()
            case .unknown:
                authorizationState = .notDetermined
                statusMessage = "HealthKit authorization status is unknown."
            @unknown default:
                authorizationState = .notDetermined
                statusMessage = "HealthKit authorization status is unknown."
            }
        } catch {
            authorizationState = .notDetermined
            lastSyncError = error.localizedDescription
            statusMessage = "Unable to determine HealthKit authorization state."
        }
    }

    private func syncWorkouts(reason: String) async {
        guard authorizationState == .ready else {
            return
        }

        guard !isSyncing else {
            return
        }

        isSyncing = true
        lastSyncError = nil
        statusMessage = "Syncing workouts (\(reason))..."
        setProgress(label: "Reading HealthKit workouts...", fraction: 0.05)

        defer {
            isSyncing = false
            clearProgress()
        }

        do {
            let hadStoredAnchor = workoutStore.hasStoredAnchor()
            let anchor = decodeAnchor(from: workoutStore.storedAnchorData())
            let anchoredResult = try await fetchAnchoredWorkouts(anchor: anchor)

            var workoutsToProcess = anchoredResult.workouts
            let pendingUUIDs = settings.automaticUploadsEnabled
                ? Set(workoutStore.pendingAutomaticUploadWorkouts.map(\.healthKitUUID))
                : Set<UUID>()

            for pendingUUID in pendingUUIDs where !workoutsToProcess.contains(where: { $0.uuid == pendingUUID }) {
                if let pendingWorkout = try await fetchWorkout(with: pendingUUID) {
                    workoutsToProcess.append(pendingWorkout)
                }
            }

            let uniqueWorkouts = workoutsToProcess
                .reduce(into: [UUID: HKWorkout]()) { partialResult, workout in
                    partialResult[workout.uuid] = workout
                }
                .values
                .sorted { $0.startDate < $1.startDate }

            let existingByUUID = Dictionary(uniqueKeysWithValues: workoutStore.workouts.map { ($0.healthKitUUID, $0) })
            var discoveredSeeds: [WorkoutModel] = []
            discoveredSeeds.reserveCapacity(uniqueWorkouts.count)
            var workoutsNeedingAutoUpload: [(workout: HKWorkout, seed: WorkoutModel)] = []

            for (index, workout) in uniqueWorkouts.enumerated() {
                let processedCount = Double(index)
                let totalCount = max(Double(uniqueWorkouts.count), 1)
                setProgress(
                    label: "Processing workout \(index + 1) of \(uniqueWorkouts.count)...",
                    fraction: 0.1 + (processedCount / totalCount) * 0.8
                )
                guard !shouldIgnore(workout: workout) else {
                    continue
                }

                let existing = existingByUUID[workout.uuid]
                let autoUploadEligible = existing?.autoUploadEligible ?? hadStoredAnchor
                let storedWorkout = makeStoredWorkout(
                    from: workout,
                    existing: existing,
                    autoUploadEligible: autoUploadEligible
                )
                discoveredSeeds.append(storedWorkout)

                if !(existing?.sentToIntervals ?? false),
                   storedWorkout.autoUploadEligible,
                   settings.automaticUploadsEnabled {
                    workoutsNeedingAutoUpload.append((workout, storedWorkout))
                }

                if index.isMultiple(of: 20) {
                    await Task.yield()
                }
            }

            workoutStore.upsertBatch(discoveredSeeds)

            for (index, pair) in workoutsNeedingAutoUpload.enumerated() {
                setProgress(
                    label: "Uploading new workout \(index + 1) of \(workoutsNeedingAutoUpload.count)...",
                    fraction: 0.82 + (Double(index) / Double(max(workoutsNeedingAutoUpload.count, 1))) * 0.1
                )

                do {
                    try await buildAndUpload(workout: pair.workout, seed: pair.seed)
                } catch {
                    workoutStore.markUploadFailed(for: pair.seed.healthKitUUID, error: error.localizedDescription)
                }

                if index.isMultiple(of: 2) {
                    await Task.yield()
                }
            }

            if let newAnchor = anchoredResult.newAnchor {
                workoutStore.updateAnchorData(encode(anchor: newAnchor))
            }

            var matchedRemoteCount: Int?
            if IntervalsConfiguration.isConfigured, !workoutStore.workouts.isEmpty {
                do {
                    setProgress(label: "Refreshing Intervals sync state...", fraction: 0.94)
                    matchedRemoteCount = try await reconcileStoredWorkoutsWithIntervals()
                } catch {
                    lastSyncError = error.localizedDescription
                }
            }

            if shouldRunLaunchMaintenance(for: reason) {
                do {
                    let deletedWalkingCount = try await deleteRemoteWalkingActivities()
                    if deletedWalkingCount > 0 {
                        showRequestBanner(
                            message: "Removed \(deletedWalkingCount) walking workout(s) from Intervals.",
                            style: .success
                        )
                    }
                } catch {
                    lastSyncError = error.localizedDescription
                }

                await performLaunchWellnessSyncIfNeeded()
                hasCompletedLaunchMaintenance = true
            }

            setProgress(label: "Finishing sync...", fraction: 1.0)

            if uniqueWorkouts.isEmpty {
                if let matchedRemoteCount {
                    statusMessage = "No new HealthKit workouts found. Matched \(matchedRemoteCount) synced workout(s) on Intervals."
                } else {
                    statusMessage = "No new HealthKit workouts found."
                }
            } else if !hadStoredAnchor {
                statusMessage = "Imported \(uniqueWorkouts.count) historical workout(s). Tap Upload on the ones you want in Intervals."
            } else if settings.automaticUploadsEnabled {
                if let matchedRemoteCount {
                    statusMessage = "Processed \(uniqueWorkouts.count) workout(s). Matched \(matchedRemoteCount) synced workout(s) on Intervals."
                } else {
                    statusMessage = "Processed \(uniqueWorkouts.count) workout(s)."
                }
            } else {
                if let matchedRemoteCount {
                    statusMessage = "Stored \(uniqueWorkouts.count) workout(s). Automatic uploads are currently off. Matched \(matchedRemoteCount) synced workout(s) on Intervals."
                } else {
                    statusMessage = "Stored \(uniqueWorkouts.count) workout(s). Automatic uploads are currently off."
                }
            }

            if preserveNextWellnessStatusSummary {
                preserveNextWellnessStatusSummary = false
            } else {
                refreshWellnessStatusSummary()
            }
        } catch {
            if Self.isCancellation(error) {
                return
            }

            if let hkError = error as? HKError, hkError.code == .errorAuthorizationDenied {
                authorizationState = .denied
            }

            lastSyncError = error.localizedDescription
            statusMessage = "Workout sync failed."
        }
    }

    private func processDiscoveredWorkout(workout: HKWorkout, autoUploadEligible: Bool) async {
        guard !shouldIgnore(workout: workout) else {
            return
        }

        let existing = workoutStore.workout(with: workout.uuid)
        let storedWorkout = makeStoredWorkout(
            from: workout,
            existing: existing,
            autoUploadEligible: autoUploadEligible
        )

        if let existing, existing.sentToIntervals {
            workoutStore.upsert(storedWorkout)
            return
        }

        workoutStore.upsert(storedWorkout)

        guard storedWorkout.autoUploadEligible, settings.automaticUploadsEnabled else {
            return
        }

        do {
            try await buildAndUpload(workout: workout, seed: storedWorkout)
        } catch {
            workoutStore.markUploadFailed(for: storedWorkout.healthKitUUID, error: error.localizedDescription)
        }
    }

    private func performWorkoutUpload(uuid: UUID) async throws -> WorkoutModel {
        let prepared = try await prepareWorkoutUpload(
            uuid: uuid,
            buildLabel: "Building workout samples...",
            buildFraction: 0.35,
            exportLabel: "Exporting workout file...",
            exportFraction: 0.5
        )
        return try await uploadPreparedWorkout(
            prepared,
            uploadLabel: "Uploading workout to Intervals...",
            uploadFraction: 0.7,
            extraStreamsLabel: "Syncing extra workout streams...",
            extraStreamsFraction: 0.82,
            shouldUploadWellness: true
        )
    }

    private func buildAndUpload(workout: HKWorkout, seed: WorkoutModel) async throws {
        let prepared = try await prepareWorkoutUpload(
            workout: workout,
            seed: seed,
            buildLabel: "Building workout samples...",
            buildFraction: 0.35,
            exportLabel: "Exporting workout file...",
            exportFraction: 0.5
        )
        _ = try await uploadPreparedWorkout(
            prepared,
            uploadLabel: "Uploading workout to Intervals...",
            uploadFraction: 0.7,
            extraStreamsLabel: "Syncing extra workout streams...",
            extraStreamsFraction: 0.82,
            shouldUploadWellness: true
        )
    }

    private func prepareWorkoutUpload(
        uuid: UUID,
        buildLabel: String,
        buildFraction: Double?,
        exportLabel: String,
        exportFraction: Double?
    ) async throws -> PreparedWorkoutUpload {
        guard authorizationState == .ready else {
            throw HKError(.errorAuthorizationDenied)
        }

        guard let workout = try await fetchWorkout(with: uuid) else {
            throw ManagerError.workoutNotFound(uuid)
        }

        guard !shouldIgnore(workout: workout) else {
            throw ManagerError.walkingWorkoutsIgnored
        }

        let seed = makeStoredWorkout(
            from: workout,
            existing: workoutStore.workout(with: uuid),
            autoUploadEligible: workoutStore.workout(with: uuid)?.autoUploadEligible ?? false
        )
        workoutStore.upsert(seed)

        return try await prepareWorkoutUpload(
            workout: workout,
            seed: seed,
            buildLabel: buildLabel,
            buildFraction: buildFraction,
            exportLabel: exportLabel,
            exportFraction: exportFraction
        )
    }

    private func prepareWorkoutUpload(
        workout: HKWorkout,
        seed: WorkoutModel,
        buildLabel: String,
        buildFraction: Double?,
        exportLabel: String,
        exportFraction: Double?
    ) async throws -> PreparedWorkoutUpload {
        setProgress(label: buildLabel, fraction: buildFraction)
        let builtWorkout = try await buildWorkoutModel(from: workout, seed: seed)
        workoutStore.upsert(builtWorkout)

        setProgress(label: exportLabel, fraction: exportFraction)
        let exportDirectory = exportDirectory
        let fileURL = try await Task.detached(priority: .utility) {
            try TCXWorkoutExporter.export(workout: builtWorkout, to: exportDirectory)
        }
        .value
        workoutStore.updateExportedFileName(for: builtWorkout.healthKitUUID, fileName: fileURL.lastPathComponent)

        return PreparedWorkoutUpload(workout: builtWorkout, fileURL: fileURL)
    }

    private func uploadPreparedWorkout(
        _ prepared: PreparedWorkoutUpload,
        uploadLabel: String,
        uploadFraction: Double?,
        extraStreamsLabel: String,
        extraStreamsFraction: Double?,
        shouldUploadWellness: Bool
    ) async throws -> WorkoutModel {
        let builtWorkout = prepared.workout
        var pairedEventID: Int?
        var plannedEventLookupError: Error?
        do {
            pairedEventID = try await explicitPlannedEventID(for: builtWorkout)
        } catch {
            plannedEventLookupError = error
        }
        let uploadParams = workoutUploadParameters(for: builtWorkout)
        workoutStore.markUploadStarted(for: builtWorkout.healthKitUUID)
        setProgress(label: uploadLabel, fraction: uploadFraction)
        let requestedExtraStreams = requestedExtraStreamTypes(for: builtWorkout)
        var streamInspectionError: String?
        var postUploadIssues: [PostUploadSyncIssue] = []
        let activityID: String?

        do {
            let uploadResponse = try await apiClient.uploadWorkoutFile(prepared.fileURL, params: uploadParams)
            if let primaryActivityID = uploadResponse.primaryActivityID {
                activityID = primaryActivityID
            } else {
                activityID = await recoverUploadedActivityID(for: builtWorkout)
            }
        } catch {
            guard Self.isRequestTimeout(error),
                  let recoveredActivityID = await recoverUploadedActivityID(for: builtWorkout) else {
                throw error
            }

            activityID = recoveredActivityID
        }

        if let activityID {
            if pairedEventID == nil, plannedEventLookupError != nil {
                do {
                    // Retry once after upload so a transient event-list hiccup does not orphan the run.
                    pairedEventID = try await explicitPlannedEventID(for: builtWorkout)
                    plannedEventLookupError = nil
                } catch {
                    plannedEventLookupError = error
                }
            }

            do {
                try await apiClient.updateActivity(
                    activityID: activityID,
                    type: builtWorkout.intervalsActivityTypeOverride
                )
            } catch {
                postUploadIssues.append(
                    PostUploadSyncIssue(
                        userMessage: "Activity type update failed for \(builtWorkout.displayName).",
                        logMessage: "Workout uploaded, but activity type update failed for \(builtWorkout.displayName): \(error.localizedDescription)"
                    )
                )
            }

            if let pairedEventID {
                do {
                    try await apiClient.updateActivity(
                        activityID: activityID,
                        pairedEventID: pairedEventID
                    )
                } catch {
                    postUploadIssues.append(
                        PostUploadSyncIssue(
                            userMessage: "Planned workout pairing failed for \(builtWorkout.displayName).",
                            logMessage: "Workout uploaded, but explicit planned workout pairing failed for \(builtWorkout.displayName): \(error.localizedDescription)"
                        )
                    )
                }
            }

            if let plannedEventLookupError {
                postUploadIssues.append(
                    PostUploadSyncIssue(
                        userMessage: "Planned workout lookup failed for \(builtWorkout.displayName).",
                        logMessage: "Workout uploaded, but planned workout lookup failed for \(builtWorkout.displayName): \(plannedEventLookupError.localizedDescription)"
                    )
                )
            }

            do {
                try await apiClient.updateActivity(
                    activityID: activityID,
                    perceivedExertion: builtWorkout.intervalsPerceivedExertion
                )
            } catch {
                postUploadIssues.append(
                    PostUploadSyncIssue(
                        userMessage: "Activity effort update failed for \(builtWorkout.displayName).",
                        logMessage: "Workout uploaded, but activity effort update failed for \(builtWorkout.displayName): \(error.localizedDescription)"
                    )
                )
            }

            do {
                setProgress(label: extraStreamsLabel, fraction: extraStreamsFraction)
                try await uploadAdditionalStreamsIfPossible(for: builtWorkout, activityID: activityID)
            } catch {
                streamInspectionError = error.localizedDescription
                postUploadIssues.append(
                    PostUploadSyncIssue(
                        userMessage: "Extra stream sync failed for \(builtWorkout.displayName).",
                        logMessage: "Workout uploaded, but extra stream sync failed for \(builtWorkout.displayName): \(error.localizedDescription)"
                    )
                )
            }

            do {
                let inspection = try await inspectRemoteExtraStreams(for: builtWorkout, activityID: activityID)
                workoutStore.updateIntervalsStreamDebug(
                    for: builtWorkout.healthKitUUID,
                    requested: inspection.requested,
                    accepted: inspection.accepted,
                    available: inspection.available,
                    error: streamInspectionError
                )
            } catch {
                let debugError = streamInspectionError ?? error.localizedDescription
                workoutStore.updateIntervalsStreamDebug(
                    for: builtWorkout.healthKitUUID,
                    requested: requestedExtraStreams,
                    accepted: [],
                    available: [],
                    error: debugError
                )
            }
        } else {
            workoutStore.updateIntervalsStreamDebug(
                for: builtWorkout.healthKitUUID,
                requested: requestedExtraStreams,
                accepted: [],
                available: [],
                error: "Intervals did not return an activity ID for stream inspection."
            )
            postUploadIssues.append(
                PostUploadSyncIssue(
                    userMessage: "Intervals did not return an activity ID for \(builtWorkout.displayName).",
                    logMessage: "Workout uploaded, but Intervals did not return an activity ID for \(builtWorkout.displayName). Planned workout pairing and stream sync were skipped."
                )
            )
        }

        if let firstIssue = postUploadIssues.first {
            lastSyncError = firstIssue.logMessage
            showRequestBanner(message: firstIssue.userMessage, style: .error)
        }

        workoutStore.markUploadSucceeded(for: builtWorkout.healthKitUUID, activityID: activityID)

        if shouldUploadWellness {
            setProgress(label: "Uploading wellness...", fraction: 0.92)
            try await uploadWellnessBackfill(through: builtWorkout.startDate)
        }

        return workoutStore.workout(with: builtWorkout.healthKitUUID) ?? builtWorkout
    }

    private struct WorkoutEffortScores: Sendable {
        let actual: Double?
        let estimated: Double?
    }

    private func workoutHeartRatePoints(for workout: HKWorkout, predicate: NSPredicate) async throws -> [SamplePoint] {
        let unit = HKUnit.count().unitDivided(by: .minute())
        let workoutLinkedPoints = try await quantityPoints(
            identifier: .heartRate,
            unit: unit,
            predicate: predicate
        )

        let overlapPredicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: []
        )
        let overlappingPoints = try await quantityPoints(
            identifier: .heartRate,
            unit: unit,
            predicate: overlapPredicate
        )

        // Strength sessions sometimes lose the workout association even though the watch recorded HR just fine.
        return mergeDistinctSamplePoints(workoutLinkedPoints + overlappingPoints)
    }

    private func workoutEffortScores(for workout: HKWorkout) async throws -> WorkoutEffortScores {
        guard #available(iOS 18.0, *) else {
            return WorkoutEffortScores(actual: nil, estimated: nil)
        }

        let predicate = HKQuery.predicateForWorkoutEffortSamplesRelated(workout: workout, activity: nil)
        async let actual = mostRecentWorkoutEffortValue(identifier: .workoutEffortScore, predicate: predicate)
        async let estimated = mostRecentWorkoutEffortValue(identifier: .estimatedWorkoutEffortScore, predicate: predicate)

        // Prefer the true effort score when Apple has one; the estimate is our backup singer.
        let actualScore = try await actual
        let estimatedScore = try await estimated

        return WorkoutEffortScores(
            actual: actualScore,
            estimated: estimatedScore
        )
    }

    private func mostRecentWorkoutEffortValue(
        identifier: HKQuantityTypeIdentifier,
        predicate: NSPredicate
    ) async throws -> Double? {
        guard #available(iOS 18.0, *),
              let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            return nil
        }

        let samples = try await fetchSamples(
            sampleType: quantityType,
            predicate: predicate,
            limit: 1,
            sortDescriptors: [
                NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            ]
        )

        return (samples.first as? HKQuantitySample)?.quantity.doubleValue(for: HKUnit.appleEffortScore())
    }

    private func makeStoredWorkout(from workout: HKWorkout, existing: WorkoutModel?, autoUploadEligible: Bool) -> WorkoutModel {
        var storedWorkout = existing ?? WorkoutModel(
            healthKitUUID: workout.uuid,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            workoutType: workout.workoutActivityType.displayName,
            sourceName: workout.sourceRevision.source.name,
            deviceName: workout.device?.name,
            totalDistanceMeters: workout.totalDistance?.doubleValue(for: .meter()),
            totalEnergyKilocalories: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
            totalElevationGainMeters: nil,
            metadata: stringify(metadata: workout.metadata),
            timeSeries: [],
            autoUploadEligible: autoUploadEligible,
            exportedFileName: nil,
            sentToIntervals: false,
            uploadState: .pending,
            lastUploadError: nil,
            lastSyncedAt: nil,
            lastAttemptedUploadAt: nil,
            intervalsActivityID: nil,
            requestedExtraStreamTypes: [],
            acceptedExtraStreamTypes: [],
            availableIntervalsStreamTypes: [],
            lastStreamInspectionAt: nil,
            lastStreamInspectionError: nil
        )

        storedWorkout.startDate = workout.startDate
        storedWorkout.endDate = workout.endDate
        storedWorkout.duration = workout.duration
        storedWorkout.workoutType = workout.workoutActivityType.displayName
        storedWorkout.sourceName = workout.sourceRevision.source.name
        storedWorkout.deviceName = workout.device?.name
        storedWorkout.totalDistanceMeters = workout.totalDistance?.doubleValue(for: .meter())
        storedWorkout.totalEnergyKilocalories = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
        storedWorkout.metadata = stringify(metadata: workout.metadata)
        storedWorkout.autoUploadEligible = existing?.autoUploadEligible ?? autoUploadEligible

        if storedWorkout.uploadState == .uploading {
            storedWorkout.uploadState = storedWorkout.sentToIntervals ? .uploaded : .pending
        }

        return storedWorkout
    }

    private func buildWorkoutModel(from workout: HKWorkout, seed: WorkoutModel) async throws -> WorkoutModel {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let startDate = workout.startDate
        let endDate = workout.endDate
        let duration = workout.duration
        let workoutType = workout.workoutActivityType.displayName
        let sourceName = workout.sourceRevision.source.name
        let deviceName = workout.device?.name
        let totalDistanceMeters = workout.totalDistance?.doubleValue(for: .meter())
        let totalEnergyKilocalories = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
        let metadata = stringify(metadata: workout.metadata)

        async let heartRate = workoutHeartRatePoints(for: workout, predicate: predicate)
        async let activeEnergy = quantityPoints(
            identifier: .activeEnergyBurned,
            unit: .kilocalorie(),
            predicate: predicate
        )
        async let basalEnergy = quantityPoints(
            identifier: .basalEnergyBurned,
            unit: .kilocalorie(),
            predicate: predicate
        )
        async let walkingRunningDistance = quantityPoints(
            identifier: .distanceWalkingRunning,
            unit: .meter(),
            predicate: predicate
        )
        async let cyclingDistance = quantityPoints(
            identifier: .distanceCycling,
            unit: .meter(),
            predicate: predicate
        )
        async let swimmingDistance = quantityPoints(
            identifier: .distanceSwimming,
            unit: .meter(),
            predicate: predicate
        )
        async let stepCount = quantityPoints(
            identifier: .stepCount,
            unit: .count(),
            predicate: predicate
        )
        async let flightsClimbed = quantityPoints(
            identifier: .flightsClimbed,
            unit: .count(),
            predicate: predicate
        )
        async let effortScores = workoutEffortScores(for: workout)
        async let route = routePoints(predicate: predicate)

        async let optionalSeries = optionalWorkoutSeries(predicate: predicate)

        let heartRatePoints = try await heartRate
        let activeEnergyPoints = try await activeEnergy
        let basalEnergyPoints = try await basalEnergy
        let walkingRunningDistancePoints = try await walkingRunningDistance
        let cyclingDistancePoints = try await cyclingDistance
        let swimmingDistancePoints = try await swimmingDistance
        let stepCountPoints = try await stepCount
        let flightsClimbedPoints = try await flightsClimbed
        let workoutEffortScores = try await effortScores
        let routePoints = try await route
        let optionalSeriesPoints = try await optionalSeries

        let mergedDistancePoints = (walkingRunningDistancePoints + cyclingDistancePoints + swimmingDistancePoints)
            .sorted { $0.date < $1.date }

        var extraSeries = optionalSeriesPoints
        extraSeries["activeEnergyKilocalories"] = activeEnergyPoints
        extraSeries["basalEnergyKilocalories"] = basalEnergyPoints
        extraSeries["stepCount"] = stepCountPoints
        extraSeries["flightsClimbed"] = flightsClimbedPoints
        let isIndoorWorkout = seed.isIndoorWorkout

        let computedSeries = await Task.detached(priority: .userInitiated) {
            let records = Self.mergeSeries(
                startDate: startDate,
                endDate: endDate,
                isIndoorWorkout: isIndoorWorkout,
                totalDistanceMeters: totalDistanceMeters,
                heartRate: heartRatePoints,
                distance: mergedDistancePoints,
                cadence: [],
                route: routePoints,
                extraSeries: extraSeries
            )
            let elevationGain = Self.totalElevationGain(from: routePoints)
            return (records, elevationGain)
        }
        .value

        var builtWorkout = seed
        builtWorkout.startDate = startDate
        builtWorkout.endDate = endDate
        builtWorkout.duration = duration
        builtWorkout.workoutType = workoutType
        builtWorkout.sourceName = sourceName
        builtWorkout.deviceName = deviceName
        builtWorkout.totalDistanceMeters = totalDistanceMeters ?? computedSeries.0.last?.distanceMeters
        builtWorkout.totalEnergyKilocalories = totalEnergyKilocalories
        builtWorkout.totalElevationGainMeters = computedSeries.1
        builtWorkout.metadata = metadata
        builtWorkout.timeSeries = computedSeries.0
        builtWorkout.workoutEffortScore = workoutEffortScores.actual
        builtWorkout.estimatedWorkoutEffortScore = workoutEffortScores.estimated
        builtWorkout.autoUploadEligible = seed.autoUploadEligible
        builtWorkout.uploadState = .pending
        builtWorkout.lastUploadError = nil
        builtWorkout.sentToIntervals = false

        return builtWorkout
    }

    private func optionalWorkoutSeries(predicate: NSPredicate) async throws -> [String: [SamplePoint]] {
        async let runningPower = quantityPoints(
            identifier: .runningPower,
            unit: .watt(),
            predicate: predicate
        )
        async let runningSpeed = quantityPoints(
            identifier: .runningSpeed,
            unit: .meter().unitDivided(by: .second()),
            predicate: predicate
        )
        async let strideLength = quantityPoints(
            identifier: .runningStrideLength,
            unit: .meter(),
            predicate: predicate
        )
        async let groundContactTime = quantityPoints(
            identifier: .runningGroundContactTime,
            unit: HKUnit.secondUnit(with: .milli),
            predicate: predicate
        )
        async let verticalOscillation = quantityPoints(
            identifier: .runningVerticalOscillation,
            unit: .meter(),
            predicate: predicate
        )
        async let strokeCount = quantityPoints(
            identifier: .swimmingStrokeCount,
            unit: .count(),
            predicate: predicate
        )

        var series: [String: [SamplePoint]] = [
            "powerWatts": try await runningPower,
            "speedMetersPerSecond": try await runningSpeed,
            "runningStrideLengthMeters": try await strideLength,
            "runningGroundContactTimeMs": try await groundContactTime,
            "runningVerticalOscillationMeters": try await verticalOscillation,
            "swimmingStrokeCount": try await strokeCount
        ]

        if #available(iOS 17.0, *) {
            async let cyclingCadence = quantityPoints(
                identifier: .cyclingCadence,
                unit: HKUnit.count().unitDivided(by: .minute()),
                predicate: predicate
            )
            async let cyclingPower = quantityPoints(
                identifier: .cyclingPower,
                unit: .watt(),
                predicate: predicate
            )

            series["cyclingCadenceRPM"] = try await cyclingCadence
            series["cyclingPowerWatts"] = try await cyclingPower
        }

        return series
    }

    nonisolated private static func mergeSeries(
        startDate: Date,
        endDate: Date,
        isIndoorWorkout: Bool,
        totalDistanceMeters: Double?,
        heartRate: [SamplePoint],
        distance: [SamplePoint],
        cadence: [SamplePoint],
        route: [RoutePoint],
        extraSeries: [String: [SamplePoint]]
    ) -> [WorkoutModel.TimeSeriesRecord] {
        var timestamps = Set<Date>([startDate, endDate])
        heartRate.forEach { timestamps.insert($0.date) }
        distance.forEach { timestamps.insert($0.date) }
        cadence.forEach { timestamps.insert($0.date) }
        route.forEach { timestamps.insert($0.date) }
        extraSeries.values.forEach { points in
            points.forEach { timestamps.insert($0.date) }
        }

        let sortedDates = timestamps.sorted()

        var heartRateCursor = SeriesCursor(points: heartRate.sorted { $0.date < $1.date }, mode: .latest)
        var distanceCursor = SeriesCursor(points: distance.sorted { $0.date < $1.date }, mode: .cumulative)
        var cadenceCursor = SeriesCursor(points: cadence.sorted { $0.date < $1.date }, mode: .latest)

        var extraCursors: [String: SeriesCursor] = extraSeries.reduce(into: [:]) { partialResult, element in
            let mode: SeriesCursor.Mode = element.key == "activeEnergyKilocalories" ||
                element.key == "basalEnergyKilocalories" ||
                element.key == "stepCount" ||
                element.key == "flightsClimbed" ? .cumulative : .latest
            partialResult[element.key] = SeriesCursor(points: element.value.sorted { $0.date < $1.date }, mode: mode)
        }

        var routeIndex = 0
        var latestRoute: RoutePoint?
        var records: [WorkoutModel.TimeSeriesRecord] = []

        for timestamp in sortedDates {
            heartRateCursor.advance(to: timestamp)
            distanceCursor.advance(to: timestamp)
            cadenceCursor.advance(to: timestamp)

            var metrics: [String: Double] = [:]
            for key in extraCursors.keys.sorted() {
                guard var cursor = extraCursors[key] else {
                    continue
                }

                cursor.advance(to: timestamp)
                extraCursors[key] = cursor
                if let value = cursor.currentValue {
                    metrics[key] = value
                }
            }

            while routeIndex < route.count, route[routeIndex].date <= timestamp {
                latestRoute = route[routeIndex]
                routeIndex += 1
            }

            let distanceMeters = distanceCursor.currentValue ?? latestRoute?.cumulativeDistance
            let rawSpeed = sanitizedRecordedSpeed(metrics["speedMetersPerSecond"] ?? latestRoute?.speed)
            let power = metrics["powerWatts"] ?? metrics["cyclingPowerWatts"]
            let cadenceRPM = cadenceCursor.currentValue
                ?? metrics["cyclingCadenceRPM"]
                ?? derivedRunningCadence(
                    speedMetersPerSecond: rawSpeed,
                    strideLengthMeters: metrics["runningStrideLengthMeters"]
                )
            let pace = rawSpeed.flatMap { $0 > 0 ? 1000.0 / $0 : nil }

            metrics.removeValue(forKey: "speedMetersPerSecond")
            metrics.removeValue(forKey: "powerWatts")
            metrics.removeValue(forKey: "cyclingPowerWatts")
            metrics.removeValue(forKey: "cyclingCadenceRPM")

            let record = WorkoutModel.TimeSeriesRecord(
                timestamp: timestamp,
                heartRate: heartRateCursor.currentValue,
                distanceMeters: distanceMeters,
                speedMetersPerSecond: rawSpeed,
                paceSecondsPerKilometer: pace,
                cadenceRPM: cadenceRPM,
                powerWatts: power,
                altitudeMeters: latestRoute?.altitude,
                latitude: latestRoute?.latitude,
                longitude: latestRoute?.longitude,
                extraMetrics: metrics
            )

            if record.hasStructuredPayload {
                records.append(record)
            }
        }

        if records.isEmpty {
            records = [
                WorkoutModel.TimeSeriesRecord(
                    timestamp: startDate,
                    heartRate: nil,
                    distanceMeters: 0,
                    speedMetersPerSecond: nil,
                    paceSecondsPerKilometer: nil,
                    cadenceRPM: nil,
                    powerWatts: nil,
                    altitudeMeters: nil,
                    latitude: nil,
                    longitude: nil,
                    extraMetrics: [:]
                ),
                WorkoutModel.TimeSeriesRecord(
                    timestamp: endDate,
                    heartRate: nil,
                    distanceMeters: totalDistanceMeters,
                    speedMetersPerSecond: nil,
                    paceSecondsPerKilometer: nil,
                    cadenceRPM: nil,
                    powerWatts: nil,
                    altitudeMeters: nil,
                    latitude: nil,
                    longitude: nil,
                    extraMetrics: [:]
                )
            ]
        }

        if let totalDistanceMeters, let lastIndex = records.indices.last, records[lastIndex].distanceMeters == nil {
            records[lastIndex].distanceMeters = totalDistanceMeters
        }

        if isIndoorWorkout {
            stabilizeIndoorSpeedAndPace(in: &records)
        } else {
            deriveMissingSpeedAndPace(in: &records)
        }

        return records
    }

    nonisolated private static func sanitizedRecordedSpeed(_ speedMetersPerSecond: Double?) -> Double? {
        guard let speedMetersPerSecond, speedMetersPerSecond.isFinite, speedMetersPerSecond > 0 else {
            return nil
        }

        return speedMetersPerSecond
    }

    nonisolated private static func deriveMissingSpeedAndPace(in records: inout [WorkoutModel.TimeSeriesRecord]) {
        for index in records.indices {
            let sanitizedSpeed = sanitizedRecordedSpeed(records[index].speedMetersPerSecond)
            records[index].speedMetersPerSecond = sanitizedSpeed
            records[index].paceSecondsPerKilometer = sanitizedSpeed.map { 1000.0 / $0 }
        }

        for index in records.indices.dropFirst() where records[index].speedMetersPerSecond == nil {
            let previous = records[index - 1]
            let current = records[index]

            guard let previousDistance = previous.distanceMeters,
                  let currentDistance = current.distanceMeters else {
                continue
            }

            let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
            let deltaDistance = currentDistance - previousDistance

            guard elapsed > 0, deltaDistance >= 0 else {
                continue
            }

            let derivedSpeed = deltaDistance / elapsed
            records[index].speedMetersPerSecond = derivedSpeed
            records[index].paceSecondsPerKilometer = derivedSpeed > 0 ? 1000.0 / derivedSpeed : nil
        }
    }

    nonisolated private static func stabilizeIndoorSpeedAndPace(in records: inout [WorkoutModel.TimeSeriesRecord]) {
        guard !records.isEmpty else {
            return
        }

        let plateauCarryForwardLimit: TimeInterval = 5
        let distanceEpsilon = 0.001

        for index in records.indices {
            let sanitizedSpeed = sanitizedRecordedSpeed(records[index].speedMetersPerSecond)
            records[index].speedMetersPerSecond = sanitizedSpeed
            records[index].paceSecondsPerKilometer = sanitizedSpeed.map { 1000.0 / $0 }
        }

        var lastDistanceAnchorIndex = records.indices.first(where: { records[$0].distanceMeters != nil })
        var lastPositiveSpeed: Double?

        for index in records.indices.dropFirst() {
            guard let currentDistance = records[index].distanceMeters else {
                continue
            }

            if lastDistanceAnchorIndex == nil {
                lastDistanceAnchorIndex = index
            }

            if let currentSpeed = records[index].speedMetersPerSecond {
                if let anchorIndex = lastDistanceAnchorIndex,
                   let anchorDistance = records[anchorIndex].distanceMeters,
                   currentDistance > anchorDistance + distanceEpsilon {
                    lastDistanceAnchorIndex = index
                }
                lastPositiveSpeed = currentSpeed
                continue
            }

            guard let anchorIndex = lastDistanceAnchorIndex,
                  let anchorDistance = records[anchorIndex].distanceMeters else {
                continue
            }

            let elapsedSinceAnchor = records[index].timestamp.timeIntervalSince(records[anchorIndex].timestamp)
            let deltaDistance = currentDistance - anchorDistance

            if elapsedSinceAnchor > 0, deltaDistance > distanceEpsilon {
                let derivedSpeed = deltaDistance / elapsedSinceAnchor
                records[index].speedMetersPerSecond = derivedSpeed
                records[index].paceSecondsPerKilometer = 1000.0 / derivedSpeed
                lastPositiveSpeed = derivedSpeed
                lastDistanceAnchorIndex = index
                continue
            }

            if abs(deltaDistance) <= distanceEpsilon,
               let lastPositiveSpeed,
               elapsedSinceAnchor <= plateauCarryForwardLimit {
                // Short plateaus usually mean sparse distance samples, not that Johnny teleported onto a couch.
                records[index].speedMetersPerSecond = lastPositiveSpeed
                records[index].paceSecondsPerKilometer = 1000.0 / lastPositiveSpeed
            }
        }
    }

    nonisolated private static func totalElevationGain(from routePoints: [RoutePoint]) -> Double? {
        guard routePoints.count > 1 else {
            return nil
        }

        var totalGain = 0.0
        var previousAltitude: Double?

        for point in routePoints {
            guard let altitude = point.altitude else {
                continue
            }

            defer { previousAltitude = altitude }

            guard let previousAltitude else {
                continue
            }

            let delta = altitude - previousAltitude
            if delta > 0 {
                totalGain += delta
            }
        }

        return totalGain > 0 ? totalGain : nil
    }

    nonisolated private static func derivedRunningCadence(speedMetersPerSecond: Double?, strideLengthMeters: Double?) -> Double? {
        guard let speedMetersPerSecond, let strideLengthMeters, strideLengthMeters > 0 else {
            return nil
        }

        return (speedMetersPerSecond / strideLengthMeters) * 60.0
    }

    private func mergeDistinctSamplePoints(_ points: [SamplePoint]) -> [SamplePoint] {
        guard !points.isEmpty else {
            return []
        }

        var mergedByTimestamp: [Date: SamplePoint] = [:]
        for point in points {
            mergedByTimestamp[point.date] = point
        }

        return mergedByTimestamp.values.sorted { $0.date < $1.date }
    }

    private func workoutUploadParameters(for workout: WorkoutModel) -> [String: String] {
        var params: [String: String] = [
            "name": "\(workout.workoutType) \(workout.startDate.formatted(date: .abbreviated, time: .shortened))",
            "device_name": workout.deviceName ?? "Apple Watch",
            "external_id": workout.externalID
        ]

        let description = """
        Synced from Apple Health by Workout Bridge.
        Source: \(workout.sourceName ?? "Unknown")
        HealthKit UUID: \(workout.healthKitUUID.uuidString)
        """
        params["description"] = description

        return params
    }

    private func recoverUploadedActivityID(for workout: WorkoutModel) async -> String? {
        let calendar = Calendar.autoupdatingCurrent
        let oldest = calendar.date(byAdding: .day, value: -1, to: workout.startDate) ?? workout.startDate
        let newest = calendar.date(byAdding: .day, value: 1, to: workout.endDate) ?? workout.endDate

        for attempt in 0..<4 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(2))
            }

            guard !Task.isCancelled else {
                return nil
            }

            guard let remoteActivities = try? await apiClient.listActivities(
                oldest: oldest,
                newest: newest,
                limit: 200
            ) else {
                continue
            }

            // A timed-out upload can still finish server-side; external_id is our breadcrumb trail.
            if let recoveredActivityID = remoteActivities.first(where: {
                $0.deleted != true && $0.externalID == workout.externalID
            })?.id {
                return recoveredActivityID
            }
        }

        return nil
    }

    private func explicitPlannedEventID(for workout: WorkoutModel) async throws -> Int? {
        guard let match = try await matchedIntervalsPlannedEvent(for: workout) else {
            return nil
        }

        if workout.requiresManualPlannedEventPairing {
            return match.id
        }

        let singleCandidateIsCloseEnough = match.candidateCount == 1 && match.bestDurationPenalty <= 45 * 60
        let clearlyBestOfMultiple = match.bestDurationPenalty <= 15 * 60 &&
            ((match.runnerUpDurationPenalty ?? Int.max) - match.bestDurationPenalty) >= 20 * 60

        return (singleCandidateIsCloseEnough || clearlyBestOfMultiple) ? match.id : nil
    }

    private func matchedIntervalsPlannedEvent(for workout: WorkoutModel) async throws -> PlannedEventMatch? {
        let workoutDay = Calendar.autoupdatingCurrent.startOfDay(for: workout.startDate)
        let events = try await apiClient.listEvents(
            oldest: workoutDay,
            newest: workoutDay,
            categories: ["WORKOUT"],
            limit: 25
        )
        let targetTypeKey = plannedEventTargetTypeKey(for: workout)
        let workoutDuration = Int(workout.duration.rounded())

        let candidates = events.filter { event in
            plannedEventTypeKey(for: event) == targetTypeKey &&
                event.pairedActivityID == nil
        }

        guard !candidates.isEmpty else {
            return nil
        }

        let rankedCandidates = candidates.sorted {
            plannedEventMatchScore(for: $0, workoutDuration: workoutDuration)
                < plannedEventMatchScore(for: $1, workoutDuration: workoutDuration)
        }
        let bestCandidate = rankedCandidates[0]
        let bestPenalty = plannedEventDurationPenalty(for: bestCandidate, workoutDuration: workoutDuration)
        let runnerUpPenalty = rankedCandidates.dropFirst().first.map {
            plannedEventDurationPenalty(for: $0, workoutDuration: workoutDuration)
        }

        return PlannedEventMatch(
            id: bestCandidate.id,
            candidateCount: rankedCandidates.count,
            bestDurationPenalty: bestPenalty,
            runnerUpDurationPenalty: runnerUpPenalty
        )
    }

    private func plannedEventTargetTypeKey(for workout: WorkoutModel) -> String {
        (workout.intervalsActivityTypeOverride ?? workout.workoutType).normalizedIntervalsTypeKey
    }

    private func plannedEventTypeKey(for event: IntervalsListedEvent) -> String {
        (event.type ?? "").normalizedIntervalsTypeKey
    }

    private func plannedEventMatchScore(for event: IntervalsListedEvent, workoutDuration: Int) -> (Int, Int) {
        (plannedEventDurationPenalty(for: event, workoutDuration: workoutDuration), event.id)
    }

    private func plannedEventDurationPenalty(for event: IntervalsListedEvent, workoutDuration: Int) -> Int {
        event.movingTime.map { abs($0 - workoutDuration) } ?? 3_600
    }

    private func uploadAdditionalStreamsIfPossible(for workout: WorkoutModel, activityID: String) async throws {
        let remoteActivityTimes = try await apiClient.fetchActivityTimeStream(activityID: activityID)
        let useSyntheticTimeBase = remoteActivityTimes.isEmpty
        let activityTimes = useSyntheticTimeBase ? syntheticActivityTimeStream(for: workout) : remoteActivityTimes
        let streams = intervalsStreams(
            for: workout,
            activityTimes: activityTimes,
            includeTimeStream: useSyntheticTimeBase
        )
        guard !streams.isEmpty else {
            return
        }

        try await apiClient.uploadActivityStreams(streams, activityID: activityID)
    }

    private func intervalsStreams(
        for workout: WorkoutModel,
        activityTimes: [Double],
        includeTimeStream: Bool = false
    ) -> [IntervalsActivityStream] {
        let trackPoints = TCXWorkoutExporter.normalizedTrackpoints(for: workout)
        guard !trackPoints.isEmpty, !activityTimes.isEmpty else {
            return []
        }

        var streams: [IntervalsActivityStream] = []

        if includeTimeStream {
            streams.append(IntervalsActivityStream(type: "time", data: activityTimes))
        }

        let heartRate = alignedStreamData(
            activityTimes: activityTimes,
            workout: workout,
            trackPoints: trackPoints
        ) { $0.heartRate }
        if heartRate.contains(where: { $0 != nil }) {
            streams.append(
                IntervalsActivityStream(
                    type: "heartrate",
                    data: heartRate
                )
            )
        }

        let strideLength = alignedStreamData(
            activityTimes: activityTimes,
            workout: workout,
            trackPoints: trackPoints
        ) { $0.extraMetrics["runningStrideLengthMeters"] }
        if strideLength.contains(where: { $0 != nil }) {
            streams.append(
                IntervalsActivityStream(
                    type: "stride_length",
                    name: "stride_length",
                    data: strideLength
                )
            )
        }

        for (metricKey, streamCode) in AppSettingsStorage.customStreamMappings().sorted(by: { $0.key < $1.key }) {
            let data = alignedStreamData(
                activityTimes: activityTimes,
                workout: workout,
                trackPoints: trackPoints
            ) { point in
                guard let rawValue = point.extraMetrics[metricKey] else {
                    return nil
                }

                return transformedCustomStreamValue(rawValue, for: metricKey)
            }
            guard data.contains(where: { $0 != nil }) else {
                continue
            }

            streams.append(
                IntervalsActivityStream(
                    type: streamCode,
                    name: streamCode,
                    data: data
                )
            )
        }

        return streams
    }

    private func syntheticActivityTimeStream(for workout: WorkoutModel) -> [Double] {
        let rawTimes = TCXWorkoutExporter.normalizedTrackpoints(for: workout)
            .map { max($0.timestamp.timeIntervalSince(workout.startDate), 0) }

        guard !rawTimes.isEmpty else {
            return []
        }

        var timeline = rawTimes
        if timeline.first.map({ $0 > 0.0001 }) ?? false {
            timeline.insert(0, at: 0)
        }

        let workoutDuration = max(workout.duration, timeline.last ?? 0)
        if timeline.last.map({ abs($0 - workoutDuration) > 0.0001 }) ?? true {
            timeline.append(workoutDuration)
        }

        return timeline.reduce(into: [Double]()) { partialResult, value in
            guard partialResult.last.map({ abs($0 - value) < 0.0001 }) != true else {
                return
            }

            partialResult.append(value)
        }
    }

    private func transformedCustomStreamValue(_ rawValue: Double, for metricKey: String) -> Double {
        switch metricKey {
        case "runningVerticalOscillationMeters":
            return rawValue * 1000.0
        default:
            return rawValue
        }
    }

    private func requestedExtraStreamTypes(for workout: WorkoutModel) -> [String] {
        let hasStrideLength = workout.timeSeries.contains { $0.extraMetrics["runningStrideLengthMeters"] != nil }
        var requested: [String] = hasStrideLength ? ["stride_length"] : []

        for (metricKey, streamCode) in AppSettingsStorage.customStreamMappings().sorted(by: { $0.key < $1.key }) {
            let hasSamples = workout.timeSeries.contains { $0.extraMetrics[metricKey] != nil }
            if hasSamples {
                requested.append(streamCode)
            }
        }

        return Array(Set(requested)).sorted()
    }

    private func inspectRemoteExtraStreams(for workout: WorkoutModel, activityID: String) async throws -> ExtraStreamInspection {
        let requested = requestedExtraStreamTypes(for: workout)
        async let remoteStreamsTask = apiClient.fetchActivityStreams(activityID: activityID)
        // Intervals occasionally plays hide-and-seek with stride_length in the unfiltered list.
        let requestedStreams = requested.isEmpty
            ? []
            : try await apiClient.fetchActivityStreams(activityID: activityID, types: requested)
        let remoteStreams = try await remoteStreamsTask
        let available = Array(
            Set(
                (remoteStreams + requestedStreams).flatMap { stream in
                    [stream.type, stream.name]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
            )
        ).sorted()
        let availableSet = Set(available)
        let accepted = requested.filter { availableSet.contains($0) }.sorted()
        return ExtraStreamInspection(requested: requested, accepted: accepted, available: available)
    }

    private func alignedStreamData(
        activityTimes: [Double],
        workout: WorkoutModel,
        trackPoints: [WorkoutModel.TimeSeriesRecord],
        value: (WorkoutModel.TimeSeriesRecord) -> Double?
    ) -> [Double?] {
        let samples = trackPoints.compactMap { point -> (seconds: Double, value: Double)? in
            guard let metricValue = value(point) else {
                return nil
            }

            let elapsed = max(point.timestamp.timeIntervalSince(workout.startDate), 0)
            return (elapsed, metricValue)
        }

        guard !samples.isEmpty else {
            return Array(repeating: nil, count: activityTimes.count)
        }

        var index = 0
        var latestValue: Double?
        var aligned: [Double?] = []
        aligned.reserveCapacity(activityTimes.count)

        for activityTime in activityTimes {
            while index < samples.count, samples[index].seconds <= activityTime + 0.0001 {
                latestValue = samples[index].value
                index += 1
            }

            aligned.append(latestValue)
        }

        return aligned
    }

    private func wellnessRecord(around workoutDate: Date) async throws -> WellnessRecord? {
        let dayID = Self.localDayFormatter.string(from: workoutDate)
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: workoutDate)
        let nextDay = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: dayStart)!
        let weightStart = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -7, to: dayStart)!
        let vo2Start = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -14, to: dayStart)!
        let bodyCompositionStart = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -14, to: dayStart)!
        let sleepSummary = (try? await sleepSummary(for: dayStart)) ?? .empty

        async let restingHeartRate = mostRecentQuantityValue(
            identifier: .restingHeartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            startDate: dayStart,
            endDate: nextDay
        )
        async let hrvSDNN = averageStatisticsQuantityValue(
            identifier: .heartRateVariabilitySDNN,
            unit: HKUnit.secondUnit(with: .milli),
            startDate: dayStart,
            endDate: nextDay
        )
        async let vo2Max = mostRecentQuantityValue(
            identifier: .vo2Max,
            unit: HKUnit(from: "ml/kg*min"),
            startDate: vo2Start,
            endDate: nextDay
        )
        async let weight = mostRecentQuantityValue(
            identifier: .bodyMass,
            unit: .gramUnit(with: .kilo),
            startDate: weightStart,
            endDate: nextDay
        )
        async let bodyFat = mostRecentQuantityValue(
            identifier: .bodyFatPercentage,
            unit: .percent(),
            startDate: bodyCompositionStart,
            endDate: nextDay
        )
        async let steps = dailyBucketedCumulativeValue(
            identifier: .stepCount,
            unit: .count(),
            startDate: dayStart,
            endDate: nextDay
        )
        async let oxygenSaturation = preferredSleepAwareQuantityValue(
            identifier: .oxygenSaturation,
            unit: .percent(),
            intervals: sleepSummary.asleepIntervals,
            dayStart: dayStart,
            dayEnd: nextDay,
            aggregation: .average
        )
        async let respiratoryRate = preferredSleepAwareQuantityValue(
            identifier: .respiratoryRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            intervals: sleepSummary.asleepIntervals,
            dayStart: dayStart,
            dayEnd: nextDay,
            aggregation: .average
        )
        async let systolic = mostRecentQuantityValue(
            identifier: .bloodPressureSystolic,
            unit: .millimeterOfMercury(),
            startDate: dayStart,
            endDate: nextDay
        )
        async let diastolic = mostRecentQuantityValue(
            identifier: .bloodPressureDiastolic,
            unit: .millimeterOfMercury(),
            startDate: dayStart,
            endDate: nextDay
        )
        async let hydrationVolume = cumulativeQuantityValue(
            identifier: .dietaryWater,
            unit: .liter(),
            startDate: dayStart,
            endDate: nextDay
        )
        async let kcalConsumed = cumulativeQuantityValue(
            identifier: .dietaryEnergyConsumed,
            unit: .kilocalorie(),
            startDate: dayStart,
            endDate: nextDay
        )
        async let carbohydrates = cumulativeQuantityValue(
            identifier: .dietaryCarbohydrates,
            unit: .gram(),
            startDate: dayStart,
            endDate: nextDay
        )
        async let protein = cumulativeQuantityValue(
            identifier: .dietaryProtein,
            unit: .gram(),
            startDate: dayStart,
            endDate: nextDay
        )
        async let fatTotal = cumulativeQuantityValue(
            identifier: .dietaryFatTotal,
            unit: .gram(),
            startDate: dayStart,
            endDate: nextDay
        )
        async let bloodGlucose = mostRecentQuantityValue(
            identifier: .bloodGlucose,
            unit: HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter()),
            startDate: dayStart,
            endDate: nextDay
        )
        let avgSleepingHeartRate = try? await estimatedSleepingHeartRate(
            unit: HKUnit.count().unitDivided(by: .minute()),
            during: sleepSummary.weightedAsleepIntervals
        )

        let record = WellnessRecord(
            id: dayID,
            weight: try? await weight,
            restingHR: (try? await restingHeartRate).map { Int($0.rounded()) },
            hrv: nil,
            hrvSDNN: try? await hrvSDNN,
            kcalConsumed: (try? await kcalConsumed).map { Int($0.rounded()) },
            vo2max: try? await vo2Max,
            steps: (try? await steps).map { Int($0.rounded()) },
            sleepSecs: sleepSummary.sleepSeconds > 0 ? Int(sleepSummary.sleepSeconds.rounded()) : nil,
            sleepScore: nil,
            sleepQuality: nil,
            avgSleepingHR: avgSleepingHeartRate,
            spO2: normalizePercentForIntervals(try? await oxygenSaturation),
            systolic: (try? await systolic).map { Int($0.rounded()) },
            diastolic: (try? await diastolic).map { Int($0.rounded()) },
            hydrationVolume: try? await hydrationVolume,
            bloodGlucose: try? await bloodGlucose,
            bodyFat: normalizePercentForIntervals(try? await bodyFat),
            respiration: try? await respiratoryRate,
            carbohydrates: try? await carbohydrates,
            protein: try? await protein,
            fatTotal: try? await fatTotal,
            locked: nil,
            comments: buildWellnessComments(from: sleepSummary)
        )

        return record.hasMeaningfulPayload ? record : nil
    }

    private func uploadWellness(for date: Date, force: Bool) async throws {
        setProgress(label: "Collecting wellness data...", fraction: force ? 0.35 : 0.92)

        guard let wellness = try await wellnessRecord(around: date) else {
            if force {
                throw ManagerError.noWellnessData(date)
            }

            return
        }

        guard force || workoutStore.shouldUploadWellness(for: wellness.id) else {
            return
        }

        setProgress(label: "Uploading wellness to Intervals...", fraction: force ? 0.75 : 0.96)
        try await apiClient.uploadWellnessBulk([wellness])
        workoutStore.markWellnessUploaded(for: wellness.id)
        lastWellnessStatusMessage = "Uploaded wellness for \(wellness.id)."
        refreshWellnessStatusSummary()
    }

    private func uploadWellnessBackfill(through workoutDate: Date) async throws {
        let calendar = Calendar.autoupdatingCurrent
        let currentDay = calendar.startOfDay(for: workoutDate)
        let previousSyncedWorkoutDay = workoutStore.workouts
            .filter { $0.sentToIntervals && $0.startDate < workoutDate }
            .map { calendar.startOfDay(for: $0.startDate) }
            .max()

        let startDay = previousSyncedWorkoutDay ?? currentDay
        let summary = try await uploadWellnessRange(from: startDay, to: currentDay, force: false)
        if summary.uploadedDays > 0 {
            lastWellnessStatusMessage = "Uploaded wellness for \(summary.uploadedDays) day(s) between workouts."
            refreshWellnessStatusSummary()
        }
    }

    private func uploadWellnessRange(from startDate: Date, to endDate: Date, force: Bool) async throws -> WellnessUploadSummary {
        let days = normalizedDayRange(from: startDate, to: endDate)
        var summary = WellnessUploadSummary()
        var batch: [WellnessRecord] = []
        let batchSize = 30

        for (index, day) in days.enumerated() {
            let dayID = Self.localDayFormatter.string(from: day)
            let progressBase = force ? 0.25 : 0.92
            let progressSpan = force ? 0.6 : 0.06
            let progressFraction = days.isEmpty ? nil : progressBase + (Double(index) / Double(max(days.count, 1))) * progressSpan
            setProgress(
                label: "Preparing wellness for \(dayID)...",
                fraction: progressFraction,
                detail: "Uploaded \(summary.uploadedDays) • Skipped \(summary.skippedDays) • Queued \(batch.count) • Day \(index + 1) of \(days.count)"
            )

            let wellness: WellnessRecord?
            do {
                wellness = try await wellnessRecord(around: day)
            } catch {
                if shouldSkipWellnessDay(for: error) {
                    summary.skippedDays += 1
                    if index.isMultiple(of: 5) {
                        await Task.yield()
                    }
                    continue
                }

                throw error
            }

            guard let wellness else {
                summary.skippedDays += 1
                if index.isMultiple(of: 5) {
                    await Task.yield()
                }
                continue
            }

            guard force || workoutStore.shouldUploadWellness(for: wellness.id) else {
                summary.skippedDays += 1
                if index.isMultiple(of: 5) {
                    await Task.yield()
                }
                continue
            }

            batch.append(wellness)

            if batch.count >= batchSize {
                try await flushWellnessBatch(
                    &batch,
                    summary: &summary,
                    progressFraction: progressFraction
                )
            }

            if index.isMultiple(of: 5) {
                await Task.yield()
            }
        }

        if !batch.isEmpty {
            try await flushWellnessBatch(&batch, summary: &summary, progressFraction: force ? 0.92 : 0.98)
        }

        return summary
    }

    private func flushWellnessBatch(
        _ batch: inout [WellnessRecord],
        summary: inout WellnessUploadSummary,
        progressFraction: Double?
    ) async throws {
        guard !batch.isEmpty else {
            return
        }

        let batchIDs = batch.map(\.id)
        setProgress(
            label: "Uploading wellness batch...",
            fraction: progressFraction,
            detail: "Sending \(batch.count) day(s): \(batchIDs.first ?? "")\(batch.count > 1 ? "..." : "")"
        )

        do {
            try await apiClient.uploadWellnessBulk(batch)
            batchIDs.forEach { workoutStore.markWellnessUploaded(for: $0) }
            summary.uploadedDays += batch.count
            batch.removeAll(keepingCapacity: true)
        } catch {
            for record in batch {
                do {
                    try await apiClient.uploadWellnessBulk([record])
                    workoutStore.markWellnessUploaded(for: record.id)
                    summary.uploadedDays += 1
                } catch {
                    summary.skippedDays += 1
                    lastSyncError = error.localizedDescription
                }
            }
            batch.removeAll(keepingCapacity: true)
        }
    }

    private func normalizedDayRange(from startDate: Date, to endDate: Date) -> [Date] {
        let calendar = Calendar.autoupdatingCurrent
        var current = calendar.startOfDay(for: min(startDate, endDate))
        let end = calendar.startOfDay(for: max(startDate, endDate))
        var days: [Date] = []

        while current <= end {
            days.append(current)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: current) else {
                break
            }
            current = nextDay
        }

        return days
    }

    private func shouldSkipWellnessDay(for error: Error) -> Bool {
        if let managerError = error as? ManagerError,
           case .noWellnessData = managerError {
            return true
        }

        let nsError = error as NSError
        let loweredDescription = nsError.localizedDescription.lowercased()

        if nsError.domain == HKError.errorDomain,
           loweredDescription.contains("no data available") {
            return true
        }

        return false
    }

    private func shouldSkipBulkWorkoutUpload(uuid: UUID) -> Bool {
        guard let workout = workoutStore.workout(with: uuid) else {
            return false
        }

        return WorkoutStore.isWalk(workout)
    }

    private func shouldIgnore(workout: HKWorkout) -> Bool {
        workout.workoutActivityType == .walking
    }

    private func shouldRunLaunchMaintenance(for reason: String) -> Bool {
        guard !hasCompletedLaunchMaintenance else {
            return false
        }

        return reason == "launch" || reason == "authorization"
    }

    private func performLaunchWellnessSyncIfNeeded() async {
        guard authorizationState == .ready else {
            return
        }

        let calendar = Calendar.autoupdatingCurrent
        let currentDay = calendar.startOfDay(for: Date())
        let daysToInclude = max(launchWellnessRecentDays - 1, 0)
        let startDay = calendar.date(byAdding: .day, value: -daysToInclude, to: currentDay) ?? currentDay

        do {
            // Always refresh a short rolling window on launch.
            // Three days is enough to be useful without making startup emotionally exhausting.
            let summary = try await uploadWellnessRange(from: startDay, to: currentDay, force: false)
            if summary.uploadedDays > 0 {
                preserveNextWellnessStatusSummary = true
                lastWellnessStatusMessage = "Uploaded wellness for \(summary.uploadedDays) recent day(s) on launch."
            }
        } catch {
            preserveNextWellnessStatusSummary = true
            lastSyncError = error.localizedDescription
            lastWellnessStatusMessage = error.localizedDescription
        }
    }

    private func deleteRemoteWalkingActivities() async throws -> Int {
        guard IntervalsConfiguration.isConfigured else {
            return 0
        }

        let now = Date()
        let oldest = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -walkingCleanupLookbackDays, to: now) ?? now
        let remoteActivities = try await apiClient.listActivities(
            oldest: oldest,
            newest: now,
            limit: 5000
        )

        let walkingActivities = remoteActivities.filter { activity in
            guard activity.deleted != true else {
                return false
            }

            let normalizedType = (activity.type ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalizedType == "walk" || normalizedType == "walking"
        }

        for activity in walkingActivities {
            guard let activityID = activity.id else {
                continue
            }

            try await apiClient.deleteActivity(activityID: activityID)
        }

        return walkingActivities.count
    }

    private func healthStoreRequestAuthorization() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HKError(.errorAuthorizationDenied))
                }
            }
        }
    }

    private func healthStoreRequestStatus() async throws -> HKAuthorizationRequestStatus {
        try await withCheckedThrowingContinuation { continuation in
            healthStore.getRequestStatusForAuthorization(toShare: [], read: readTypes) { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    private func configureBackgroundDelivery() async throws {
        let success = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            healthStore.enableBackgroundDelivery(for: HKObjectType.workoutType(), frequency: .immediate) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: success)
            }
        }

        backgroundDeliveryEnabled = success
    }

    private func startWorkoutObserverIfNeeded() {
        guard observerQuery == nil else {
            return
        }

        let query = HKObserverQuery(sampleType: HKObjectType.workoutType(), predicate: nil) { [weak self] _, completionHandler, error in
            guard let self else {
                completionHandler()
                return
            }

            if let error {
                Task { @MainActor in
                    self.lastSyncError = error.localizedDescription
                    self.statusMessage = "Workout observer failed."
                }
                completionHandler()
                return
            }

            Task {
                await self.syncWorkouts(reason: "background delivery")
                completionHandler()
            }
        }

        observerQuery = query
        healthStore.execute(query)
    }

    private func fetchAnchoredWorkouts(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], newAnchor: HKQueryAnchor?) {
        let sampleType = HKObjectType.workoutType()

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: nil,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let workouts = (samples as? [HKWorkout]) ?? []
                continuation.resume(returning: (workouts, newAnchor))
            }

            self.healthStore.execute(query)
        }
    }

    private func fetchWorkout(with uuid: UUID) async throws -> HKWorkout? {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: HKQuery.predicateForObject(with: uuid),
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: samples?.first as? HKWorkout)
            }

            healthStore.execute(query)
        }
    }

    private func quantityPoints(identifier: HKQuantityTypeIdentifier, unit: HKUnit, predicate: NSPredicate) async throws -> [SamplePoint] {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            return []
        }

        let samples = try await fetchSamples(
            sampleType: quantityType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [
                NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
            ]
        )

        return samples.compactMap { sample in
            guard let quantitySample = sample as? HKQuantitySample else {
                return nil
            }

            return SamplePoint(
                date: quantitySample.endDate,
                value: quantitySample.quantity.doubleValue(for: unit)
            )
        }
    }

    private func routePoints(predicate: NSPredicate) async throws -> [RoutePoint] {
        let samples = try await fetchSamples(
            sampleType: HKSeriesType.workoutRoute(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [
                NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            ]
        )

        let routes = samples.compactMap { $0 as? HKWorkoutRoute }
        guard !routes.isEmpty else {
            return []
        }

        var allLocations: [CLLocation] = []
        for route in routes {
            let locations = try await routeLocations(for: route)
            allLocations.append(contentsOf: locations)
        }

        let sortedLocations = allLocations.sorted { $0.timestamp < $1.timestamp }
        var routePoints: [RoutePoint] = []
        var previousLocation: CLLocation?
        var cumulativeDistance = 0.0

        for location in sortedLocations {
            if let previousLocation {
                cumulativeDistance += max(location.distance(from: previousLocation), 0)
            }

            routePoints.append(
                RoutePoint(
                    date: location.timestamp,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                    speed: location.speed >= 0 ? location.speed : nil,
                    cumulativeDistance: cumulativeDistance
                )
            )

            previousLocation = location
        }

        return routePoints
    }

    private func routeLocations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            var collectedLocations: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, locationsOrNil, done, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let locationsOrNil {
                    collectedLocations.append(contentsOf: locationsOrNil)
                }

                if done {
                    continuation.resume(returning: collectedLocations)
                }
            }

            healthStore.execute(query)
        }
    }

    private func fetchSamples(
        sampleType: HKSampleType,
        predicate: NSPredicate?,
        limit: Int,
        sortDescriptors: [NSSortDescriptor]?
    ) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: sortDescriptors
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: samples ?? [])
            }

            healthStore.execute(query)
        }
    }

    private func mostRecentQuantityValue(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        startDate: Date,
        endDate: Date
    ) async throws -> Double? {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            return nil
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [])
        let samples = try await fetchSamples(
            sampleType: quantityType,
            predicate: predicate,
            limit: 1,
            sortDescriptors: [
                NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            ]
        )

        return (samples.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
    }

    private func cumulativeStatisticsQuantityValue(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        startDate: Date,
        endDate: Date
    ) async throws -> Double? {
        let value = try await statisticsQuantityValue(
            identifier: identifier,
            unit: unit,
            startDate: startDate,
            endDate: endDate,
            options: .cumulativeSum
        )

        return value.map { $0 > 0 ? $0 : 0 }
    }

    private func dailyBucketedCumulativeValue(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        startDate: Date,
        endDate: Date
    ) async throws -> Double? {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            return nil
        }

        let calendar = Calendar.autoupdatingCurrent
        let anchorDate = calendar.startOfDay(for: startDate)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [])
        var interval = DateComponents()
        interval.day = 1

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchorDate,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let statistic = collection?.statistics(for: anchorDate)
                let value = statistic?.sumQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: value.map { $0 > 0 ? $0 : 0 })
            }

            healthStore.execute(query)
        }
    }

    private func averageStatisticsQuantityValue(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        startDate: Date,
        endDate: Date
    ) async throws -> Double? {
        try await statisticsQuantityValue(
            identifier: identifier,
            unit: unit,
            startDate: startDate,
            endDate: endDate,
            options: .discreteAverage
        )
    }

    private func cumulativeQuantityValue(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        startDate: Date,
        endDate: Date
    ) async throws -> Double? {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            return nil
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [])
        let samples = try await fetchSamples(
            sampleType: quantityType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        )

        let total = samples
            .compactMap { $0 as? HKQuantitySample }
            .map { $0.quantity.doubleValue(for: unit) }
            .reduce(0, +)

        return total > 0 ? total : nil
    }

    private func statisticsQuantityValue(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        startDate: Date,
        endDate: Date,
        options: HKStatisticsOptions
    ) async throws -> Double? {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            return nil
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: [.strictStartDate, .strictEndDate]
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: options
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let quantity: HKQuantity?
                if options.contains(.cumulativeSum) {
                    quantity = statistics?.sumQuantity()
                } else if options.contains(.discreteAverage) {
                    quantity = statistics?.averageQuantity()
                } else {
                    quantity = nil
                }

                continuation.resume(returning: quantity?.doubleValue(for: unit))
            }

            healthStore.execute(query)
        }
    }

    private enum QuantityAggregation {
        case average
        case latest
    }

    private func sleepSummary(for dayStart: Date) async throws -> SleepSummary {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return SleepSummary(
                asleepIntervals: [],
                weightedAsleepIntervals: [],
                sleepSeconds: 0,
                inBedSeconds: 0,
                awakeSeconds: 0,
                remSeconds: 0,
                deepSeconds: 0,
                coreSeconds: 0,
                unspecifiedAsleepSeconds: 0
            )
        }

        let calendar = Calendar.autoupdatingCurrent
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let previousDay = calendar.date(byAdding: .day, value: -1, to: dayStart)!
        let predicate = HKQuery.predicateForSamples(withStart: previousDay, end: nextDay, options: [])

        let samples = try await fetchSamples(
            sampleType: sleepType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [
                NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
            ]
        )

        var asleepIntervals: [DateInterval] = []
        var weightedAsleepIntervals: [WeightedSleepInterval] = []
        var sleepSeconds = 0.0
        var inBedSeconds = 0.0
        var awakeSeconds = 0.0
        var remSeconds = 0.0
        var deepSeconds = 0.0
        var coreSeconds = 0.0
        var unspecifiedAsleepSeconds = 0.0

        for sample in samples.compactMap({ $0 as? HKCategorySample }) where calendar.isDate(sample.endDate, inSameDayAs: dayStart) {
            let duration = sample.endDate.timeIntervalSince(sample.startDate)
            guard duration > 0 else {
                continue
            }

            let interval = DateInterval(start: sample.startDate, end: sample.endDate)

            if let stageWeight = Self.sleepStageWeight(for: sample.value) {
                asleepIntervals.append(interval)
                weightedAsleepIntervals.append(
                    WeightedSleepInterval(interval: interval, stageWeight: stageWeight)
                )
                sleepSeconds += duration
            }

            if #available(iOS 16.0, *) {
                switch sample.value {
                case HKCategoryValueSleepAnalysis.inBed.rawValue:
                    inBedSeconds += duration
                case HKCategoryValueSleepAnalysis.awake.rawValue:
                    awakeSeconds += duration
                case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                    remSeconds += duration
                case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                    deepSeconds += duration
                case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                    coreSeconds += duration
                case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                    unspecifiedAsleepSeconds += duration
                default:
                    break
                }
            } else {
                switch sample.value {
                case HKCategoryValueSleepAnalysis.inBed.rawValue:
                    inBedSeconds += duration
                case HKCategoryValueSleepAnalysis.awake.rawValue:
                    awakeSeconds += duration
                case HKCategoryValueSleepAnalysis.asleep.rawValue:
                    unspecifiedAsleepSeconds += duration
                default:
                    break
                }
            }
        }

        return SleepSummary(
            asleepIntervals: asleepIntervals,
            weightedAsleepIntervals: weightedAsleepIntervals,
            sleepSeconds: sleepSeconds,
            inBedSeconds: inBedSeconds,
            awakeSeconds: awakeSeconds,
            remSeconds: remSeconds,
            deepSeconds: deepSeconds,
            coreSeconds: coreSeconds,
            unspecifiedAsleepSeconds: unspecifiedAsleepSeconds
        )
    }

    private func preferredSleepAwareQuantityValue(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        intervals: [DateInterval],
        dayStart: Date,
        dayEnd: Date,
        aggregation: QuantityAggregation
    ) async throws -> Double? {
        if !intervals.isEmpty {
            switch aggregation {
            case .average:
                if let intervalAverage = try await averageQuantityValue(identifier: identifier, unit: unit, during: intervals) {
                    return intervalAverage
                }
            case .latest:
                if let intervalLatest = try await latestQuantityValue(identifier: identifier, unit: unit, during: intervals) {
                    return intervalLatest
                }
            }
        }

        return try await mostRecentQuantityValue(
            identifier: identifier,
            unit: unit,
            startDate: dayStart,
            endDate: dayEnd
        )
    }

    private func estimatedSleepingHeartRate(
        unit: HKUnit,
        during intervals: [WeightedSleepInterval]
    ) async throws -> Double? {
        guard let earliestStart = intervals.map(\.interval.start).min(),
              let latestEnd = intervals.map(\.interval.end).max(),
              let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            return nil
        }

        let predicate = HKQuery.predicateForSamples(withStart: earliestStart, end: latestEnd, options: [])
        let samples = try await fetchSamples(
            sampleType: heartRateType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [
                NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            ]
        )

        let segments = buildWeightedHeartRateSegments(
            from: samples.compactMap { $0 as? HKQuantitySample },
            unit: unit,
            sleepIntervals: intervals
        )

        guard !segments.isEmpty else {
            return nil
        }

        if let sustainedLow = lowestSustainedHeartRate(
            from: segments,
            windowDuration: 30 * 60,
            minimumCoveredDuration: 20 * 60
        ) {
            return sustainedLow
        }

        // Fallback keeps the estimate useful on sparse nights instead of rage-quitting on Johnny.
        return weightedHeartRateAverage(for: segments)
    }

    private func averageQuantityValue(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        during intervals: [DateInterval]
    ) async throws -> Double? {
        guard let earliestStart = intervals.map(\.start).min(),
              let latestEnd = intervals.map(\.end).max() else {
            return nil
        }

        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            return nil
        }

        let predicate = HKQuery.predicateForSamples(withStart: earliestStart, end: latestEnd, options: [])
        let samples = try await fetchSamples(
            sampleType: quantityType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [
                NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
            ]
        )

        let values = samples
            .compactMap { $0 as? HKQuantitySample }
            .filter { sample in
                intervals.contains { $0.intersects(DateInterval(start: sample.startDate, end: sample.endDate)) }
            }
            .map { $0.quantity.doubleValue(for: unit) }

        guard !values.isEmpty else {
            return nil
        }

        // Average over interval-matching samples keeps the payload honest without pretending we own a sleep lab.
        return values.reduce(0, +) / Double(values.count)
    }

    private func buildWeightedHeartRateSegments(
        from samples: [HKQuantitySample],
        unit: HKUnit,
        sleepIntervals: [WeightedSleepInterval]
    ) -> [WeightedHeartRateSegment] {
        let sortedSamples = samples.sorted { $0.startDate < $1.startDate }
        guard !sortedSamples.isEmpty else {
            return []
        }

        return sortedSamples.enumerated().compactMap { index, sample in
            let midpoint = sampleMidpoint(for: sample)
            guard let matchingInterval = sleepIntervals.first(where: { $0.interval.contains(midpoint) }) else {
                return nil
            }

            let previousMidpoint = index > 0 ? sampleMidpoint(for: sortedSamples[index - 1]) : nil
            let nextMidpoint = index + 1 < sortedSamples.count ? sampleMidpoint(for: sortedSamples[index + 1]) : nil
            let segmentStart = previousMidpoint.map { midpoint.timeIntervalSince($0) / 2 + $0.timeIntervalSinceReferenceDate } ?? (midpoint.timeIntervalSinceReferenceDate - 30)
            let segmentEnd = nextMidpoint.map { $0.timeIntervalSince(midpoint) / 2 + midpoint.timeIntervalSinceReferenceDate } ?? (midpoint.timeIntervalSinceReferenceDate + 30)
            let interval = DateInterval(
                start: Date(timeIntervalSinceReferenceDate: max(segmentStart, matchingInterval.interval.start.timeIntervalSinceReferenceDate)),
                end: Date(timeIntervalSinceReferenceDate: min(segmentEnd, matchingInterval.interval.end.timeIntervalSinceReferenceDate))
            )

            guard interval.duration > 0 else {
                return nil
            }

            return WeightedHeartRateSegment(
                interval: interval,
                heartRate: sample.quantity.doubleValue(for: unit),
                stageWeight: matchingInterval.stageWeight
            )
        }
    }

    private func lowestSustainedHeartRate(
        from segments: [WeightedHeartRateSegment],
        windowDuration: TimeInterval,
        minimumCoveredDuration: TimeInterval
    ) -> Double? {
        let sortedSegments = segments.sorted { $0.interval.start < $1.interval.start }
        var best: Double?

        for segment in sortedSegments {
            let window = DateInterval(start: segment.interval.end.addingTimeInterval(-windowDuration), end: segment.interval.end)
            var weightedTotal = 0.0
            var weightTotal = 0.0
            var coveredDuration = 0.0

            for candidate in sortedSegments {
                let overlap = overlapDuration(between: candidate.interval, and: window)
                guard overlap > 0 else {
                    continue
                }

                weightedTotal += candidate.heartRate * overlap * candidate.stageWeight
                weightTotal += overlap * candidate.stageWeight
                coveredDuration += overlap
            }

            guard coveredDuration >= minimumCoveredDuration, weightTotal > 0 else {
                continue
            }

            let estimate = weightedTotal / weightTotal
            best = min(best ?? estimate, estimate)
        }

        return best
    }

    private func weightedHeartRateAverage(for segments: [WeightedHeartRateSegment]) -> Double? {
        var weightedTotal = 0.0
        var weightTotal = 0.0

        for segment in segments {
            weightedTotal += segment.heartRate * segment.interval.duration * segment.stageWeight
            weightTotal += segment.interval.duration * segment.stageWeight
        }

        guard weightTotal > 0 else {
            return nil
        }

        return weightedTotal / weightTotal
    }

    private func latestQuantityValue(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        during intervals: [DateInterval]
    ) async throws -> Double? {
        guard let earliestStart = intervals.map(\.start).min(),
              let latestEnd = intervals.map(\.end).max() else {
            return nil
        }

        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            return nil
        }

        let predicate = HKQuery.predicateForSamples(withStart: earliestStart, end: latestEnd, options: [])
        let samples = try await fetchSamples(
            sampleType: quantityType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [
                NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            ]
        )

        return samples
            .compactMap { $0 as? HKQuantitySample }
            .first { sample in
                intervals.contains { $0.intersects(DateInterval(start: sample.startDate, end: sample.endDate)) }
            }?
            .quantity
            .doubleValue(for: unit)
    }

    private func normalizePercentForIntervals(_ value: Double?) -> Double? {
        guard let value, value >= 0 else {
            return nil
        }

        // Apple Health percentage samples often behave like 0...1 scalars; Intervals wants 0...100.
        return value <= 1 ? value * 100 : value
    }

    private func buildWellnessComments(from sleepSummary: SleepSummary) -> String? {
        var segments: [String] = []

        if sleepSummary.hasStageDetail {
            var stageBits: [String] = []

            if sleepSummary.inBedSeconds > 0 {
                stageBits.append("in bed \(formattedDuration(sleepSummary.inBedSeconds))")
            }
            if sleepSummary.sleepSeconds > 0 {
                stageBits.append("asleep \(formattedDuration(sleepSummary.sleepSeconds))")
            }
            if sleepSummary.coreSeconds > 0 {
                stageBits.append("core \(formattedDuration(sleepSummary.coreSeconds))")
            }
            if sleepSummary.deepSeconds > 0 {
                stageBits.append("deep \(formattedDuration(sleepSummary.deepSeconds))")
            }
            if sleepSummary.remSeconds > 0 {
                stageBits.append("REM \(formattedDuration(sleepSummary.remSeconds))")
            }
            if sleepSummary.awakeSeconds > 0 {
                stageBits.append("awake \(formattedDuration(sleepSummary.awakeSeconds))")
            }
            if sleepSummary.unspecifiedAsleepSeconds > 0, sleepSummary.coreSeconds == 0, sleepSummary.deepSeconds == 0, sleepSummary.remSeconds == 0 {
                stageBits.append("asleep-unspecified \(formattedDuration(sleepSummary.unspecifiedAsleepSeconds))")
            }

            if !stageBits.isEmpty {
                segments.append("Sleep detail: \(stageBits.joined(separator: ", "))")
            }
        }

        guard !segments.isEmpty else {
            return nil
        }

        return segments.joined(separator: ". ")
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = Int((duration / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }

    private func sampleMidpoint(for sample: HKQuantitySample) -> Date {
        sample.startDate.addingTimeInterval(sample.endDate.timeIntervalSince(sample.startDate) / 2)
    }

    private func overlapDuration(between lhs: DateInterval, and rhs: DateInterval) -> TimeInterval {
        let start = max(lhs.start, rhs.start)
        let end = min(lhs.end, rhs.end)
        return max(0, end.timeIntervalSince(start))
    }

    private func reconcileStoredWorkoutsWithIntervals() async throws -> Int {
        let storedWorkouts = workoutStore.workouts
        guard !storedWorkouts.isEmpty else {
            return 0
        }

        let calendar = Calendar.autoupdatingCurrent
        let earliestDate = storedWorkouts.map(\.startDate).min() ?? Date()
        let latestDate = storedWorkouts.map(\.endDate).max() ?? Date()
        let oldest = calendar.date(byAdding: .day, value: -7, to: earliestDate) ?? earliestDate
        let newest = calendar.date(byAdding: .day, value: 7, to: latestDate) ?? latestDate
        let remoteActivities = try await apiClient.listActivities(
            oldest: oldest,
            newest: newest,
            limit: max(storedWorkouts.count * 3, 500)
        )

        let syncedActivityIDs = remoteActivities.reduce(into: [String: String]()) { partialResult, activity in
            guard activity.deleted != true,
                  let externalID = activity.externalID,
                  let activityID = activity.id else {
                return
            }

            partialResult[externalID] = activityID
        }

        return workoutStore.reconcileRemoteActivities(activityIDsByExternalID: syncedActivityIDs)
    }

    private func showRequestBanner(message: String, style: RequestStatusBanner.Style) {
        bannerDismissTask?.cancel()
        requestBanner = RequestStatusBanner(message: message, style: style)

        bannerDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            self?.requestBanner = nil
        }
    }

    private func encode(anchor: HKQueryAnchor?) -> Data? {
        guard let anchor else {
            return nil
        }

        return try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    private func decodeAnchor(from data: Data?) -> HKQueryAnchor? {
        guard let data else {
            return nil
        }

        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func stringify(metadata: [String: Any]?) -> [String: String] {
        guard let metadata else {
            return [:]
        }

        return metadata.reduce(into: [:]) { partialResult, element in
            partialResult[element.key] = String(describing: element.value)
        }
    }

    private func setProgress(label: String, fraction: Double?, detail: String? = nil) {
        syncProgressLabel = label
        syncProgressFraction = fraction.map { min(max($0, 0), 1) }
        syncProgressDetail = detail
    }

    private func clearProgress() {
        syncProgressLabel = nil
        syncProgressFraction = nil
        syncProgressDetail = nil
    }

    private func refreshWellnessStatusSummary() {
        if let latestUpload = workoutStore.latestWellnessUpload {
            lastWellnessStatusMessage = "Wellness synced for \(workoutStore.wellnessUploadCount) day(s). Latest day: \(latestUpload.dateID)."
        } else {
            lastWellnessStatusMessage = "No wellness days have been uploaded yet."
        }
    }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]

        [
            HKQuantityTypeIdentifier.heartRate,
            .activeEnergyBurned,
            .basalEnergyBurned,
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming,
            .restingHeartRate,
            .heartRateVariabilitySDNN,
            .vo2Max,
            .bodyMass,
            .bodyFatPercentage,
            .stepCount,
            .oxygenSaturation,
            .bloodPressureSystolic,
            .bloodPressureDiastolic,
            .bloodGlucose,
            .respiratoryRate,
            .dietaryWater,
            .dietaryEnergyConsumed,
            .dietaryCarbohydrates,
            .dietaryProtein,
            .dietaryFatTotal,
            .runningPower,
            .runningSpeed,
            .runningStrideLength,
            .runningGroundContactTime,
            .runningVerticalOscillation,
            .flightsClimbed,
            .swimmingStrokeCount
        ].compactMap(HKObjectType.quantityType(forIdentifier:)).forEach { types.insert($0) }

        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleepType)
        }

        if #available(iOS 17.0, *) {
            [HKQuantityTypeIdentifier.cyclingCadence, .cyclingPower]
                .compactMap(HKObjectType.quantityType(forIdentifier:))
                .forEach { types.insert($0) }
        }

        if #available(iOS 18.0, *) {
            [HKQuantityTypeIdentifier.workoutEffortScore, .estimatedWorkoutEffortScore]
                .compactMap(HKObjectType.quantityType(forIdentifier:))
                .forEach { types.insert($0) }
        }

        return types
    }

    private static let localDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .autoupdatingCurrent
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func sleepStageWeight(for value: Int) -> Double? {
        switch value {
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
            return 1.0
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
            return 0.9
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
            return 0.7
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
            return 0.75
        case 0:
            // Legacy pre-iOS 16 "asleep". Old data never got the memo, apparently.
            return 0.75
        default:
            return nil
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func isRequestTimeout(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }
}

private extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .cycling:
            return "Ride"
        case .elliptical:
            return "Elliptical"
        case .functionalStrengthTraining, .traditionalStrengthTraining:
            return "Weight Training"
        case .hiking:
            return "Hike"
        case .highIntensityIntervalTraining:
            return "HIIT"
        case .mixedCardio:
            return "Mixed Cardio"
        case .rowing:
            return "Row"
        case .running:
            return "Run"
        case .swimming:
            return "Swim"
        case .walking:
            return "Walk"
        case .yoga:
            return "Yoga"
        default:
            return "Workout"
        }
    }
}

private extension String {
    var normalizedIntervalsTypeKey: String {
        lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
