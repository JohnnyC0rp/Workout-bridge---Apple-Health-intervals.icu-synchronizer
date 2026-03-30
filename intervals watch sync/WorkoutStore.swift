//
//  WorkoutStore.swift
//  intervals watch sync
//
//  Created by Codex on 24/03/2026.
//

import Combine
import Dispatch
import Foundation

fileprivate struct WorkoutStorePersistedState: Codable, Sendable {
    var workouts: [WorkoutModel]
    var workoutAnchorDataBase64: String?
    var lastAnchoredSyncAt: Date?
    var wellnessUploadDates: [String: Date]
}

fileprivate struct WorkoutStoreSanitizedLoadResult: Sendable {
    let state: WorkoutStorePersistedState
    let didSanitizeStoredWorkouts: Bool
}

@MainActor
final class WorkoutStore: ObservableObject {
    @Published private(set) var workouts: [WorkoutModel] = []
    @Published private(set) var lastAnchoredSyncAt: Date?

    private let fileManager: FileManager
    private let storageURL: URL
    private let saveQueue = DispatchQueue(label: "com.johnnycorp.intervals-watch-sync.workout-store-save", qos: .utility)
    private var workoutAnchorData: Data?
    private var wellnessUploadDates: [String: Date] = [:]
    private var hasLoadedFromDisk = false

    init(fileManager: FileManager = .default, loadImmediately: Bool = true) {
        self.fileManager = fileManager

        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.storageURL = supportDirectory
            .appendingPathComponent("WorkoutBridge", isDirectory: true)
            .appendingPathComponent("workout-store.json", isDirectory: false)

        if loadImmediately {
            Task {
                await loadIfNeeded()
            }
        }
    }

    func loadIfNeeded() async {
        guard !hasLoadedFromDisk else {
            return
        }

        hasLoadedFromDisk = true

        let storageURL = storageURL
        let loadedResult = await Task.detached(priority: .utility) {
            try? Self.loadSanitizedState(from: storageURL)
        }
        .value

        guard let loadedResult else {
            return
        }

        let state = loadedResult.state
        workouts = state.workouts
        lastAnchoredSyncAt = state.lastAnchoredSyncAt
        workoutAnchorData = state.workoutAnchorDataBase64.flatMap { Data(base64Encoded: $0) }
        wellnessUploadDates = state.wellnessUploadDates

        if loadedResult.didSanitizeStoredWorkouts {
            scheduleSave()
        }
    }

    var pendingWorkouts: [WorkoutModel] {
        workouts
            .filter { !$0.sentToIntervals }
            .sorted { $0.startDate < $1.startDate }
    }

    var visibleWorkouts: [WorkoutModel] {
        workouts
    }

    var visiblePendingWorkouts: [WorkoutModel] {
        workouts
            .filter { !$0.sentToIntervals }
            .sorted { $0.startDate < $1.startDate }
    }

    var visibleSyncedWorkouts: [WorkoutModel] {
        workouts
            .filter(\.sentToIntervals)
    }

    var pendingAutomaticUploadWorkouts: [WorkoutModel] {
        workouts
            .filter { !$0.sentToIntervals && $0.autoUploadEligible }
            .sorted { $0.startDate < $1.startDate }
    }

    var wellnessUploadCount: Int {
        wellnessUploadDates.count
    }

    var latestWellnessUpload: (dateID: String, uploadedAt: Date)? {
        wellnessUploadDates.max { $0.value < $1.value }
            .map { (dateID: $0.key, uploadedAt: $0.value) }
    }

    var latestNonWalkWorkoutDate: Date? {
        workouts.first?.startDate
    }

    func workout(with uuid: UUID) -> WorkoutModel? {
        workouts.first(where: { $0.healthKitUUID == uuid })
    }

    nonisolated static func isWalk(_ workout: WorkoutModel) -> Bool {
        workout.workoutType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "walk"
    }

    func hasStoredAnchor() -> Bool {
        workoutAnchorData != nil
    }

    func storedAnchorData() -> Data? {
        workoutAnchorData
    }

    func updateAnchorData(_ data: Data?) {
        workoutAnchorData = data
        lastAnchoredSyncAt = Date()
        scheduleSave()
    }

    func upsert(_ workout: WorkoutModel) {
        if Self.isWalk(workout) {
            workouts.removeAll { $0.healthKitUUID == workout.healthKitUUID }
            scheduleSave()
            return
        }

        if let index = workouts.firstIndex(where: { $0.healthKitUUID == workout.healthKitUUID }) {
            workouts[index] = workout
        } else {
            workouts.append(workout)
        }

        workouts.sort { $0.startDate > $1.startDate }
        scheduleSave()
    }

    func upsertBatch(_ incomingWorkouts: [WorkoutModel]) {
        guard !incomingWorkouts.isEmpty else {
            return
        }

        var mergedByUUID = Dictionary(uniqueKeysWithValues: workouts.map { ($0.healthKitUUID, $0) })

        for workout in incomingWorkouts where !Self.isWalk(workout) {
            mergedByUUID[workout.healthKitUUID] = workout
        }

        workouts = Array(mergedByUUID.values).sorted { $0.startDate > $1.startDate }
        scheduleSave()
    }

    func markUploadStarted(for uuid: UUID) {
        mutateWorkout(with: uuid) { workout in
            workout.uploadState = .uploading
            workout.lastAttemptedUploadAt = Date()
            workout.lastUploadError = nil
        }
    }

    func markUploadSucceeded(for uuid: UUID, activityID: String?) {
        mutateWorkout(with: uuid) { workout in
            workout.sentToIntervals = true
            workout.uploadState = .uploaded
            workout.lastUploadError = nil
            workout.lastSyncedAt = Date()
            workout.intervalsActivityID = activityID
        }
    }

    func markUploadFailed(for uuid: UUID, error: String) {
        mutateWorkout(with: uuid) { workout in
            workout.sentToIntervals = false
            workout.uploadState = .failed
            workout.lastAttemptedUploadAt = Date()
            workout.lastUploadError = error
        }
    }

    func markDeletedFromIntervals(for uuid: UUID) {
        mutateWorkout(with: uuid) { workout in
            workout.sentToIntervals = false
            workout.uploadState = .pending
            workout.lastUploadError = nil
            workout.intervalsActivityID = nil
            workout.requestedExtraStreamTypes = []
            workout.acceptedExtraStreamTypes = []
            workout.availableIntervalsStreamTypes = []
            workout.lastStreamInspectionAt = nil
            workout.lastStreamInspectionError = nil
        }
    }

    func updateExportedFileName(for uuid: UUID, fileName: String) {
        mutateWorkout(with: uuid) { workout in
            workout.exportedFileName = fileName
        }
    }

    func updateIntervalsStreamDebug(
        for uuid: UUID,
        requested: [String],
        accepted: [String],
        available: [String],
        error: String?
    ) {
        mutateWorkout(with: uuid) { workout in
            workout.requestedExtraStreamTypes = requested.sorted()
            workout.acceptedExtraStreamTypes = accepted.sorted()
            workout.availableIntervalsStreamTypes = available.sorted()
            workout.lastStreamInspectionAt = Date()
            workout.lastStreamInspectionError = error
        }
    }

    func shouldUploadWellness(for dateID: String, maxAge: TimeInterval = 12 * 60 * 60) -> Bool {
        guard let uploadedAt = wellnessUploadDates[dateID] else {
            return true
        }

        return Date().timeIntervalSince(uploadedAt) > maxAge
    }

    func markWellnessUploaded(for dateID: String) {
        wellnessUploadDates[dateID] = Date()
        scheduleSave()
    }

    @discardableResult
    func reconcileRemoteActivities(activityIDsByExternalID: [String: String]) -> Int {
        var matchedCount = 0
        var didChange = false

        for index in workouts.indices {
            let externalID = workouts[index].externalID
            if let activityID = activityIDsByExternalID[externalID] {
                matchedCount += 1

                if !workouts[index].sentToIntervals ||
                    workouts[index].uploadState != .uploaded ||
                    workouts[index].intervalsActivityID != activityID {
                    workouts[index].sentToIntervals = true
                    workouts[index].uploadState = .uploaded
                    workouts[index].lastUploadError = nil
                    workouts[index].intervalsActivityID = activityID
                    workouts[index].lastSyncedAt = workouts[index].lastSyncedAt ?? Date()
                    didChange = true
                }
            } else if workouts[index].sentToIntervals || workouts[index].intervalsActivityID != nil {
                workouts[index].sentToIntervals = false
                workouts[index].uploadState = .pending
                workouts[index].lastUploadError = nil
                workouts[index].intervalsActivityID = nil
                didChange = true
            }
        }

        if didChange {
            workouts.sort { $0.startDate > $1.startDate }
            scheduleSave()
        }

        return matchedCount
    }

    private func mutateWorkout(with uuid: UUID, mutation: (inout WorkoutModel) -> Void) {
        guard let index = workouts.firstIndex(where: { $0.healthKitUUID == uuid }) else {
            return
        }

        mutation(&workouts[index])
        workouts.sort { $0.startDate > $1.startDate }
        scheduleSave()
    }

    private func scheduleSave() {
        let state = WorkoutStorePersistedState(
            workouts: workouts,
            workoutAnchorDataBase64: workoutAnchorData?.base64EncodedString(),
            lastAnchoredSyncAt: lastAnchoredSyncAt,
            wellnessUploadDates: wellnessUploadDates
        )
        let storageURL = storageURL

        saveQueue.async {
            do {
                try Self.writeState(state, to: storageURL)
            } catch {
                print("WorkoutStore save failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func loadSanitizedState(from storageURL: URL) throws -> WorkoutStoreSanitizedLoadResult {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return WorkoutStoreSanitizedLoadResult(
                state: WorkoutStorePersistedState(
                    workouts: [],
                    workoutAnchorDataBase64: nil,
                    lastAnchoredSyncAt: nil,
                    wellnessUploadDates: [:]
                ),
                didSanitizeStoredWorkouts: false
            )
        }

        let data = try Data(contentsOf: storageURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var state = try decoder.decode(WorkoutStorePersistedState.self, from: data)
        let sanitizedWorkouts = state.workouts
            .filter { !Self.isWalk($0) }
            .sorted { $0.startDate > $1.startDate }
        let didSanitizeStoredWorkouts = sanitizedWorkouts.count != state.workouts.count ||
            sanitizedWorkouts.map(\.healthKitUUID) != state.workouts.map(\.healthKitUUID)
        state.workouts = sanitizedWorkouts
        return WorkoutStoreSanitizedLoadResult(
            state: state,
            didSanitizeStoredWorkouts: didSanitizeStoredWorkouts
        )
    }

    nonisolated private static func writeState(_ state: WorkoutStorePersistedState, to storageURL: URL) throws {
        let directoryURL = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(state)
        // Tiny JSON persistence keeps the project honest without inviting Core Data to a two-line problem.
        try data.write(to: storageURL, options: .atomic)
    }
}
