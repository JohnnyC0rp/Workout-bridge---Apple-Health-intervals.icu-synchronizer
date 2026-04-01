//
//  WorkoutModel.swift
//  intervals watch sync
//
//  Created by Codex on 24/03/2026.
//

import Foundation

struct WorkoutModel: Identifiable, Codable, Hashable, Sendable {
    enum UploadState: String, Codable, Hashable {
        case pending
        case uploading
        case uploaded
        case failed
    }

    struct TimeSeriesRecord: Codable, Hashable, Sendable {
        var timestamp: Date
        var heartRate: Double?
        var distanceMeters: Double?
        var speedMetersPerSecond: Double?
        var paceSecondsPerKilometer: Double?
        var cadenceRPM: Double?
        var powerWatts: Double?
        var altitudeMeters: Double?
        var latitude: Double?
        var longitude: Double?
        var extraMetrics: [String: Double]

        var hasStructuredPayload: Bool {
            heartRate != nil ||
            distanceMeters != nil ||
            speedMetersPerSecond != nil ||
            cadenceRPM != nil ||
            powerWatts != nil ||
            altitudeMeters != nil ||
            latitude != nil ||
            longitude != nil ||
            !extraMetrics.isEmpty
        }
    }

    let healthKitUUID: UUID
    var startDate: Date
    var endDate: Date
    var duration: TimeInterval
    var workoutType: String
    var sourceName: String?
    var deviceName: String?
    var totalDistanceMeters: Double?
    var totalEnergyKilocalories: Double?
    var totalElevationGainMeters: Double?
    var metadata: [String: String]
    var timeSeries: [TimeSeriesRecord]
    var autoUploadEligible: Bool
    var exportedFileName: String?
    var sentToIntervals: Bool
    var uploadState: UploadState
    var lastUploadError: String?
    var lastSyncedAt: Date?
    var lastAttemptedUploadAt: Date?
    var intervalsActivityID: String?
    var requestedExtraStreamTypes: [String]
    var acceptedExtraStreamTypes: [String]
    var availableIntervalsStreamTypes: [String]
    var lastStreamInspectionAt: Date?
    var lastStreamInspectionError: String?
    var workoutEffortScore: Double?
    var estimatedWorkoutEffortScore: Double?

    var id: UUID { healthKitUUID }

    var externalID: String {
        "healthkit-\(healthKitUUID.uuidString.lowercased())"
    }

    var displayName: String {
        workoutType
    }

    var intervalsActivityTypeOverride: String? {
        switch workoutType.normalizedWorkoutTypeKey {
        case "weighttraining", "strength":
            return "WeightTraining"
        case "hiit":
            return "HiiT"
        default:
            return nil
        }
    }

    var requiresManualPlannedEventPairing: Bool {
        isIndoorWorkout || intervalsActivityTypeOverride != nil
    }

    var isIndoorWorkout: Bool {
        let indoorMetadataKeys = [
            "HKIndoorWorkout",
            "HKMetadataKeyIndoorWorkout",
            "_HKPrivateMetadataKeyIndoorWorkout",
            "IndoorWorkout"
        ]

        for key in indoorMetadataKeys {
            guard let rawValue = metadata[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() else {
                continue
            }

            switch rawValue {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                continue
            }
        }

        return false
    }

    var effectiveWorkoutEffortScore: Double? {
        let effortScore = workoutEffortScore ?? estimatedWorkoutEffortScore
        guard let effortScore, effortScore > 0 else {
            return nil
        }

        return min(max(effortScore, 1), 10)
    }

    var intervalsSessionRPE: Int? {
        effectiveWorkoutEffortScore.map { Int($0.rounded()) }
    }

    var intervalsPerceivedExertion: Double? {
        effectiveWorkoutEffortScore
    }

    var averageHeartRate: Double? {
        let samples = timeSeries.compactMap(\.heartRate)
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    var maximumHeartRate: Double? {
        timeSeries.compactMap(\.heartRate).max()
    }

    var maximumPower: Double? {
        timeSeries.compactMap(\.powerWatts).max()
    }

    init(
        healthKitUUID: UUID,
        startDate: Date,
        endDate: Date,
        duration: TimeInterval,
        workoutType: String,
        sourceName: String?,
        deviceName: String?,
        totalDistanceMeters: Double?,
        totalEnergyKilocalories: Double?,
        totalElevationGainMeters: Double?,
        metadata: [String: String],
        timeSeries: [TimeSeriesRecord],
        autoUploadEligible: Bool,
        exportedFileName: String?,
        sentToIntervals: Bool,
        uploadState: UploadState,
        lastUploadError: String?,
        lastSyncedAt: Date?,
        lastAttemptedUploadAt: Date?,
        intervalsActivityID: String?,
        requestedExtraStreamTypes: [String],
        acceptedExtraStreamTypes: [String],
        availableIntervalsStreamTypes: [String],
        lastStreamInspectionAt: Date?,
        lastStreamInspectionError: String?,
        workoutEffortScore: Double? = nil,
        estimatedWorkoutEffortScore: Double? = nil
    ) {
        self.healthKitUUID = healthKitUUID
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.workoutType = workoutType
        self.sourceName = sourceName
        self.deviceName = deviceName
        self.totalDistanceMeters = totalDistanceMeters
        self.totalEnergyKilocalories = totalEnergyKilocalories
        self.totalElevationGainMeters = totalElevationGainMeters
        self.metadata = metadata
        self.timeSeries = timeSeries
        self.autoUploadEligible = autoUploadEligible
        self.exportedFileName = exportedFileName
        self.sentToIntervals = sentToIntervals
        self.uploadState = uploadState
        self.lastUploadError = lastUploadError
        self.lastSyncedAt = lastSyncedAt
        self.lastAttemptedUploadAt = lastAttemptedUploadAt
        self.intervalsActivityID = intervalsActivityID
        self.requestedExtraStreamTypes = requestedExtraStreamTypes
        self.acceptedExtraStreamTypes = acceptedExtraStreamTypes
        self.availableIntervalsStreamTypes = availableIntervalsStreamTypes
        self.lastStreamInspectionAt = lastStreamInspectionAt
        self.lastStreamInspectionError = lastStreamInspectionError
        self.workoutEffortScore = workoutEffortScore
        self.estimatedWorkoutEffortScore = estimatedWorkoutEffortScore
    }

    enum CodingKeys: String, CodingKey {
        case healthKitUUID
        case startDate
        case endDate
        case duration
        case workoutType
        case sourceName
        case deviceName
        case totalDistanceMeters
        case totalEnergyKilocalories
        case totalElevationGainMeters
        case metadata
        case timeSeries
        case autoUploadEligible
        case exportedFileName
        case sentToIntervals
        case uploadState
        case lastUploadError
        case lastSyncedAt
        case lastAttemptedUploadAt
        case intervalsActivityID
        case requestedExtraStreamTypes
        case acceptedExtraStreamTypes
        case availableIntervalsStreamTypes
        case lastStreamInspectionAt
        case lastStreamInspectionError
        case workoutEffortScore
        case estimatedWorkoutEffortScore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        healthKitUUID = try container.decode(UUID.self, forKey: .healthKitUUID)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decode(Date.self, forKey: .endDate)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        workoutType = try container.decode(String.self, forKey: .workoutType)
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        totalDistanceMeters = try container.decodeIfPresent(Double.self, forKey: .totalDistanceMeters)
        totalEnergyKilocalories = try container.decodeIfPresent(Double.self, forKey: .totalEnergyKilocalories)
        totalElevationGainMeters = try container.decodeIfPresent(Double.self, forKey: .totalElevationGainMeters)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        timeSeries = try container.decodeIfPresent([TimeSeriesRecord].self, forKey: .timeSeries) ?? []
        autoUploadEligible = try container.decodeIfPresent(Bool.self, forKey: .autoUploadEligible) ?? true
        exportedFileName = try container.decodeIfPresent(String.self, forKey: .exportedFileName)
        sentToIntervals = try container.decodeIfPresent(Bool.self, forKey: .sentToIntervals) ?? false
        uploadState = try container.decodeIfPresent(UploadState.self, forKey: .uploadState) ?? .pending
        lastUploadError = try container.decodeIfPresent(String.self, forKey: .lastUploadError)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        lastAttemptedUploadAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptedUploadAt)
        intervalsActivityID = try container.decodeIfPresent(String.self, forKey: .intervalsActivityID)
        requestedExtraStreamTypes = try container.decodeIfPresent([String].self, forKey: .requestedExtraStreamTypes) ?? []
        acceptedExtraStreamTypes = try container.decodeIfPresent([String].self, forKey: .acceptedExtraStreamTypes) ?? []
        availableIntervalsStreamTypes = try container.decodeIfPresent([String].self, forKey: .availableIntervalsStreamTypes) ?? []
        lastStreamInspectionAt = try container.decodeIfPresent(Date.self, forKey: .lastStreamInspectionAt)
        lastStreamInspectionError = try container.decodeIfPresent(String.self, forKey: .lastStreamInspectionError)
        workoutEffortScore = try container.decodeIfPresent(Double.self, forKey: .workoutEffortScore)
        estimatedWorkoutEffortScore = try container.decodeIfPresent(Double.self, forKey: .estimatedWorkoutEffortScore)
    }
}

private extension String {
    var normalizedWorkoutTypeKey: String {
        lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

struct WellnessRecord: Codable, Hashable, Sendable {
    var id: String
    var weight: Double?
    var restingHR: Int?
    var hrv: Double?
    var hrvSDNN: Double?
    var kcalConsumed: Int?
    var vo2max: Double?
    var steps: Int?
    var sleepSecs: Int?
    var sleepScore: Double?
    var sleepQuality: Int?
    var avgSleepingHR: Double?
    var spO2: Double?
    var systolic: Int?
    var diastolic: Int?
    var hydrationVolume: Double?
    var bloodGlucose: Double?
    var bodyFat: Double?
    var respiration: Double?
    var carbohydrates: Double?
    var protein: Double?
    var fatTotal: Double?
    var locked: Bool?
    var comments: String?

    var hasMeaningfulPayload: Bool {
        weight != nil ||
        restingHR != nil ||
        hrv != nil ||
        hrvSDNN != nil ||
        kcalConsumed != nil ||
        vo2max != nil ||
        steps != nil ||
        sleepSecs != nil ||
        sleepScore != nil ||
        sleepQuality != nil ||
        avgSleepingHR != nil ||
        spO2 != nil ||
        systolic != nil ||
        diastolic != nil ||
        hydrationVolume != nil ||
        bloodGlucose != nil ||
        bodyFat != nil ||
        respiration != nil ||
        carbohydrates != nil ||
        protein != nil ||
        fatTotal != nil
    }
}
