//
//  AppSettings.swift
//  intervals watch sync
//
//  Created by Codex on 24/03/2026.
//

import Combine
import Foundation

enum IntervalsExtraStreamSetting: String, CaseIterable, Identifiable {
    case groundContactTime
    case verticalOscillation
    case flightsClimbed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .groundContactTime:
            return "Ground contact time stream code"
        case .verticalOscillation:
            return "Vertical oscillation stream code"
        case .flightsClimbed:
            return "Flights climbed stream code"
        }
    }

    var placeholder: String {
        switch self {
        case .groundContactTime:
            return "Leave blank to use default code"
        case .verticalOscillation:
            return "Leave blank to use default code"
        case .flightsClimbed:
            return "Optional custom code"
        }
    }

    var helpText: String {
        switch self {
        case .groundContactTime:
            return "Uploads HealthKit ground contact time using your Intervals custom stream code, or the default GroundContactTime code if left blank."
        case .verticalOscillation:
            return "Uploads HealthKit vertical oscillation using your Intervals custom stream code, or the default VerticalOscillation code if left blank. Intervals should define this stream in mm."
        case .flightsClimbed:
            return "Optional only. Enter a custom Intervals stream code if you decide to chart flights climbed later."
        }
    }

    var metricKey: String {
        switch self {
        case .groundContactTime:
            return "runningGroundContactTimeMs"
        case .verticalOscillation:
            return "runningVerticalOscillationMeters"
        case .flightsClimbed:
            return "flightsClimbed"
        }
    }

    var defaultCode: String? {
        switch self {
        case .groundContactTime:
            return "GroundContactTime"
        case .verticalOscillation:
            return "VerticalOscillation"
        case .flightsClimbed:
            return nil
        }
    }
}

enum AppSettingsStorage {
    private static let athleteIDKey = "intervals.athleteID"
    private static let automaticUploadsEnabledKey = "intervals.automaticUploadsEnabled"

    static func athleteID(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: athleteIDKey) ?? "0"
    }

    static func normalizedAthleteID(defaults: UserDefaults = .standard) -> String {
        let trimmed = athleteID(defaults: defaults).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "0" : trimmed
    }

    static func setAthleteID(_ athleteID: String, defaults: UserDefaults = .standard) {
        defaults.set(athleteID, forKey: athleteIDKey)
    }

    static func automaticUploadsEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: automaticUploadsEnabledKey) == nil {
            return true
        }

        return defaults.bool(forKey: automaticUploadsEnabledKey)
    }

    static func setAutomaticUploadsEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: automaticUploadsEnabledKey)
    }

    static func customStreamCode(for setting: IntervalsExtraStreamSetting, defaults: UserDefaults = .standard) -> String? {
        let trimmed = (defaults.string(forKey: customStreamKey(for: setting)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func effectiveCustomStreamCode(for setting: IntervalsExtraStreamSetting, defaults: UserDefaults = .standard) -> String? {
        customStreamCode(for: setting, defaults: defaults) ?? setting.defaultCode
    }

    static func setCustomStreamCode(_ value: String, for setting: IntervalsExtraStreamSetting, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: customStreamKey(for: setting))
    }

    static func customStreamMappings(defaults: UserDefaults = .standard) -> [String: String] {
        IntervalsExtraStreamSetting.allCases.reduce(into: [:]) { partialResult, setting in
            if let code = effectiveCustomStreamCode(for: setting, defaults: defaults) {
                partialResult[setting.metricKey] = code
            }
        }
    }

    private static func customStreamKey(for setting: IntervalsExtraStreamSetting) -> String {
        "intervals.customStream.\(setting.rawValue)"
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var athleteID: String {
        didSet {
            AppSettingsStorage.setAthleteID(athleteID, defaults: defaults)
        }
    }

    @Published var automaticUploadsEnabled: Bool {
        didSet {
            AppSettingsStorage.setAutomaticUploadsEnabled(automaticUploadsEnabled, defaults: defaults)
        }
    }

    @Published private var customStreamCodes: [IntervalsExtraStreamSetting: String]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.athleteID = AppSettingsStorage.athleteID(defaults: defaults)
        self.automaticUploadsEnabled = AppSettingsStorage.automaticUploadsEnabled(defaults: defaults)
        self.customStreamCodes = IntervalsExtraStreamSetting.allCases.reduce(into: [:]) { partialResult, setting in
            partialResult[setting] = AppSettingsStorage.customStreamCode(for: setting, defaults: defaults) ?? ""
        }
    }

    func customStreamCode(for setting: IntervalsExtraStreamSetting) -> String {
        customStreamCodes[setting, default: ""]
    }

    func effectiveCustomStreamCode(for setting: IntervalsExtraStreamSetting) -> String? {
        let override = customStreamCode(for: setting).trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? setting.defaultCode : override
    }

    func setCustomStreamCode(_ value: String, for setting: IntervalsExtraStreamSetting) {
        customStreamCodes[setting] = value
        AppSettingsStorage.setCustomStreamCode(value, for: setting, defaults: defaults)
    }

    var normalizedAthleteID: String {
        AppSettingsStorage.normalizedAthleteID(defaults: defaults)
    }

    var automaticUploadsStatusText: String {
        automaticUploadsEnabled
            ? "Uploads new workouts automatically and backfills wellness across the days between synced workouts."
            : "Only stores workouts locally until you tap Upload."
    }
}
