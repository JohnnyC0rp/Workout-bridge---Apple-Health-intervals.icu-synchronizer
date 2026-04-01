//
//  TCXWorkoutExporter.swift
//  intervals watch sync
//
//  Created by Codex on 24/03/2026.
//

import Foundation

enum TCXWorkoutExporter {
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    nonisolated(unsafe) fileprivate static let posixLocale = Locale(identifier: "en_US_POSIX")

    nonisolated static func export(workout: WorkoutModel, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("HKWorkout-\(workout.healthKitUUID.uuidString).tcx")
        let xml = render(workout: workout)
        try xml.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    nonisolated static func render(workout: WorkoutModel) -> String {
        let trackPoints = normalizedTrackpoints(for: workout)
        let totalDistance = workout.totalDistanceMeters ?? trackPoints.last?.distanceMeters ?? 0
        let maximumSpeed = trackPoints.compactMap(\.speedMetersPerSecond).max() ?? 0
        let calories = Int((workout.totalEnergyKilocalories ?? 0).rounded())

        let averageHeartRateXML = workout.averageHeartRate.map {
            """
                    <AverageHeartRateBpm>
                        <Value>\(Int($0.rounded()))</Value>
                    </AverageHeartRateBpm>
            """
        } ?? ""

        let maximumHeartRateXML = workout.maximumHeartRate.map {
            """
                    <MaximumHeartRateBpm>
                        <Value>\(Int($0.rounded()))</Value>
                    </MaximumHeartRateBpm>
            """
        } ?? ""

        let cadenceXML = averageCadence(for: trackPoints).map {
            "                <Cadence>\(Int($0.rounded()))</Cadence>"
        } ?? ""

        let notes = """
        Synced from Apple Health / Apple Watch by Workout Bridge.
        Source: \(workout.sourceName ?? "Unknown")
        Device: \(workout.deviceName ?? "Unknown")
        """

        let trackXML = trackPoints.map(trackpointXML).joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase
            xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
            xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2"
            xmlns:ns4="https://workoutbridge.app/xmlschemas/HealthKitExtensions/v1"
            xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd
            http://www.garmin.com/xmlschemas/ActivityExtension/v2 http://www.garmin.com/xmlschemas/ActivityExtensionv2.xsd">
            <Activities>
                <Activity Sport="\(tcxSport(for: workout.workoutType))">
                    <Id>\(dateFormatter.string(from: workout.startDate))</Id>
                    <Lap StartTime="\(dateFormatter.string(from: workout.startDate))">
                        <TotalTimeSeconds>\(workout.duration.decimalString)</TotalTimeSeconds>
                        <DistanceMeters>\(totalDistance.decimalString)</DistanceMeters>
                        <MaximumSpeed>\(maximumSpeed.decimalString)</MaximumSpeed>
                        <Calories>\(calories)</Calories>
        \(averageHeartRateXML)
        \(maximumHeartRateXML)
                        <Intensity>Active</Intensity>
        \(cadenceXML)
                        <TriggerMethod>Manual</TriggerMethod>
                        <Track>
        \(trackXML)
                        </Track>
                    </Lap>
                    <Notes>\(renderNotes(for: workout, baseNotes: notes).xmlEscaped)</Notes>
                </Activity>
            </Activities>
            <Author xsi:type="Application_t">
                <Name>Workout Bridge</Name>
                <Build>
                    <Version>
                        <VersionMajor>1</VersionMajor>
                        <VersionMinor>0</VersionMinor>
                        <BuildMajor>1</BuildMajor>
                        <BuildMinor>0</BuildMinor>
                    </Version>
                </Build>
                <LangID>en</LangID>
                <PartNumber>000-00000-00</PartNumber>
            </Author>
        </TrainingCenterDatabase>
        """
    }

    nonisolated static func normalizedTrackpoints(for workout: WorkoutModel) -> [WorkoutModel.TimeSeriesRecord] {
        let filtered = workout.timeSeries
            .filter(\.hasStructuredPayload)
            .sorted { $0.timestamp < $1.timestamp }

        guard !filtered.isEmpty else {
            return [
                WorkoutModel.TimeSeriesRecord(
                    timestamp: workout.startDate,
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
                    timestamp: workout.endDate,
                    heartRate: nil,
                    distanceMeters: workout.totalDistanceMeters,
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

        return filtered
    }

    nonisolated private static func averageCadence(for trackPoints: [WorkoutModel.TimeSeriesRecord]) -> Double? {
        let cadence = trackPoints.compactMap(\.cadenceRPM)
        guard !cadence.isEmpty else { return nil }
        return cadence.reduce(0, +) / Double(cadence.count)
    }

    nonisolated private static func trackpointXML(_ point: WorkoutModel.TimeSeriesRecord) -> String {
        let positionXML: String
        if let latitude = point.latitude, let longitude = point.longitude {
            positionXML = """
                            <Position>
                                <LatitudeDegrees>\(latitude.coordinateDecimalString)</LatitudeDegrees>
                                <LongitudeDegrees>\(longitude.coordinateDecimalString)</LongitudeDegrees>
                            </Position>
            """
        } else {
            positionXML = ""
        }

        let altitudeXML = point.altitudeMeters.map {
            "                        <AltitudeMeters>\($0.decimalString)</AltitudeMeters>"
        } ?? ""

        let distanceXML = point.distanceMeters.map {
            "                        <DistanceMeters>\($0.decimalString)</DistanceMeters>"
        } ?? ""

        let heartRateXML = point.heartRate.map {
            """
                            <HeartRateBpm>
                                <Value>\(Int($0.rounded()))</Value>
                            </HeartRateBpm>
            """
        } ?? ""

        let cadenceXML = point.cadenceRPM.map {
            "                        <Cadence>\(Int($0.rounded()))</Cadence>"
        } ?? ""

        let extensionsXML = extensionsXML(point)

        return """
                            <Trackpoint>
                                <Time>\(dateFormatter.string(from: point.timestamp))</Time>
        \(positionXML)
        \(altitudeXML)
        \(distanceXML)
        \(heartRateXML)
        \(cadenceXML)
        \(extensionsXML)
                            </Trackpoint>
        """
    }

    nonisolated private static func extensionsXML(_ point: WorkoutModel.TimeSeriesRecord) -> String {
        let speedXML = point.speedMetersPerSecond.map {
            "                                <ns3:Speed>\($0.decimalString)</ns3:Speed>"
        } ?? ""

        let wattsXML = point.powerWatts.map {
            "                                <ns3:Watts>\($0.decimalString)</ns3:Watts>"
        } ?? ""

        let cadenceXML = point.cadenceRPM.map {
            "                                <ns3:RunCadence>\(Int($0.rounded()))</ns3:RunCadence>"
        } ?? ""

        let tpxXML: String
        if speedXML.isEmpty && wattsXML.isEmpty && cadenceXML.isEmpty {
            tpxXML = ""
        } else {
            tpxXML = [
                "                                    <ns3:TPX>",
                speedXML,
                wattsXML,
                cadenceXML,
                "                                    </ns3:TPX>"
            ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        }

        let extraExtensions = [
            xmlLine(tag: "ns4:StrideLengthMeters", value: point.extraMetrics["runningStrideLengthMeters"]),
            xmlLine(tag: "ns4:GroundContactTimeMs", value: point.extraMetrics["runningGroundContactTimeMs"]),
            xmlLine(tag: "ns4:VerticalOscillationMeters", value: point.extraMetrics["runningVerticalOscillationMeters"]),
            xmlLine(tag: "ns4:FlightsClimbed", value: point.extraMetrics["flightsClimbed"]),
            xmlLine(tag: "ns4:ActiveEnergyKilocalories", value: point.extraMetrics["activeEnergyKilocalories"]),
            xmlLine(tag: "ns4:BasalEnergyKilocalories", value: point.extraMetrics["basalEnergyKilocalories"]),
            xmlLine(tag: "ns4:StepCount", value: point.extraMetrics["stepCount"]),
            xmlLine(tag: "ns4:SwimmingStrokeCount", value: point.extraMetrics["swimmingStrokeCount"])
        ]
            .compactMap { $0 }
            .joined(separator: "\n")

        guard !tpxXML.isEmpty || !extraExtensions.isEmpty else {
            return ""
        }

        return """
                                <Extensions>
        \(tpxXML)
        \(extraExtensions)
                                </Extensions>
        """
    }

    nonisolated private static func renderNotes(for workout: WorkoutModel, baseNotes: String) -> String {
        let summaries = [
            summaryLine(label: "Avg stride length", value: averageExtraMetric("runningStrideLengthMeters", in: workout), suffix: "m"),
            summaryLine(label: "Avg ground contact time", value: averageExtraMetric("runningGroundContactTimeMs", in: workout), suffix: "ms"),
            summaryLine(label: "Avg vertical oscillation", value: averageExtraMetric("runningVerticalOscillationMeters", in: workout), suffix: "m"),
            summaryLine(label: "Flights climbed", value: latestExtraMetric("flightsClimbed", in: workout), suffix: nil)
        ]
            .compactMap { $0 }
            .joined(separator: "\n")

        guard !summaries.isEmpty else {
            return baseNotes
        }

        return """
        \(baseNotes)

        Extra metrics
        \(summaries)
        """
    }

    nonisolated private static func averageExtraMetric(_ key: String, in workout: WorkoutModel) -> Double? {
        let values = workout.timeSeries.compactMap { $0.extraMetrics[key] }
        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
    }

    nonisolated private static func latestExtraMetric(_ key: String, in workout: WorkoutModel) -> Double? {
        workout.timeSeries
            .compactMap { $0.extraMetrics[key] }
            .last
    }

    nonisolated private static func summaryLine(label: String, value: Double?, suffix: String?) -> String? {
        guard let value else {
            return nil
        }

        let renderedValue = suffix.map { "\(value.decimalString) \($0)" } ?? value.decimalString
        return "\(label): \(renderedValue)"
    }

    nonisolated private static func xmlLine(tag: String, value: Double?) -> String? {
        guard let value else {
            return nil
        }

        return "                                <\(tag)>\(value.decimalString)</\(tag)>"
    }

    nonisolated private static func tcxSport(for workoutType: String) -> String {
        let value = workoutType.lowercased()
        if value.contains("ride") || value.contains("bike") || value.contains("cycle") {
            return "Biking"
        }

        if value.contains("run") || value.contains("walk") || value.contains("hike") {
            return "Running"
        }

        return "Other"
    }
}

private extension Double {
    var decimalString: String {
        String(format: "%.3f", locale: TCXWorkoutExporter.posixLocale, self)
    }

    var coordinateDecimalString: String {
        // GPS deserves special treatment; six decimals is plenty precise without inflating TCX size into drama.
        String(format: "%.6f", locale: TCXWorkoutExporter.posixLocale, self)
    }
}

private extension String {
    var xmlEscaped: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
