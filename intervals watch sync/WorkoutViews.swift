//
//  WorkoutViews.swift
//  intervals watch sync
//
//  Created by Codex on 27/03/2026.
//

import SwiftUI

struct WorkoutRowView: View {
    let workout: WorkoutModel
    let canUpload: Bool
    let canDeleteRemote: Bool
    let onUpload: () -> Void
    let onRefreshStreams: () -> Void
    let onDelete: () -> Void

    @State private var isShowingStreamDebug = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workout.displayName)
                        .font(.headline)
                    Text(workout.startDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StatusBadge(state: workout.uploadState)
            }

            HStack(spacing: 12) {
                metricLabel(systemName: "timer", text: workout.duration.formattedDuration)

                if let distance = workout.totalDistanceMeters {
                    metricLabel(systemName: "figure.run", text: distance.formattedDistance)
                }

                if let averageHeartRate = workout.averageHeartRate {
                    metricLabel(systemName: "heart.fill", text: "\(Int(averageHeartRate.rounded())) bpm")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !workout.autoUploadEligible && !workout.sentToIntervals {
                Text("Historical workout. It stays local until you tap Upload.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if workout.timeSeries.isEmpty && !workout.sentToIntervals {
                Text("Detailed Apple Watch samples will be fetched when this workout is uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(buttonTitle, action: onUpload)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canUpload || workout.uploadState == .uploading || workout.sentToIntervals)

                if workout.sentToIntervals {
                    Button("Delete from Intervals", role: .destructive, action: onDelete)
                        .buttonStyle(.bordered)
                        .disabled(!canDeleteRemote || workout.uploadState == .uploading || workout.intervalsActivityID == nil)
                }
            }

            if workout.sentToIntervals {
                Text("Synced with Intervals: \(workout.intervalsActivityID ?? "linked")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if workout.sentToIntervals {
                DisclosureGroup("Intervals Stream Debug", isExpanded: $isShowingStreamDebug) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Requested extra workout streams: \(requestedSummary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !workout.requestedExtraStreamTypes.isEmpty {
                            ForEach(workout.requestedExtraStreamTypes, id: \.self) { streamType in
                                HStack {
                                    Image(systemName: workout.acceptedExtraStreamTypes.contains(streamType) ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(workout.acceptedExtraStreamTypes.contains(streamType) ? .green : .orange)
                                    Text(streamType)
                                        .font(.caption.monospaced())
                                    Spacer()
                                    Text(workout.acceptedExtraStreamTypes.contains(streamType) ? "Accepted" : "Missing")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(workout.acceptedExtraStreamTypes.contains(streamType) ? .green : .orange)
                                }
                            }
                        }

                        if !workout.availableIntervalsStreamTypes.isEmpty {
                            Text("Intervals currently exposes: \(workout.availableIntervalsStreamTypes.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let lastInspected = workout.lastStreamInspectionAt {
                            Text("Last checked: \(lastInspected.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let inspectionError = workout.lastStreamInspectionError {
                            Text(inspectionError)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Button("Refresh Stream Debug", action: onRefreshStreams)
                            .buttonStyle(.bordered)
                            .disabled(workout.uploadState == .uploading || workout.intervalsActivityID == nil)
                    }
                    .padding(.top, 4)
                }
                .font(.subheadline.weight(.semibold))
            }

            if let fileName = workout.exportedFileName {
                Text("Export: \(fileName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let lastUploadError = workout.lastUploadError {
                Text(lastUploadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private var buttonTitle: String {
        switch workout.uploadState {
        case .failed:
            return "Retry Upload"
        case .uploaded:
            return "Synced"
        case .uploading:
            return "Uploading..."
        case .pending:
            return "Upload"
        }
    }

    private var requestedSummary: String {
        workout.requestedExtraStreamTypes.isEmpty
            ? "none detected in this workout"
            : workout.requestedExtraStreamTypes.joined(separator: ", ")
    }

    @ViewBuilder
    private func metricLabel(systemName: String, text: String) -> some View {
        Label(text, systemImage: systemName)
    }
}

struct CompactWorkoutCard: View {
    let workout: WorkoutModel
    let canUpload: Bool
    let onUpload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workout.displayName)
                        .font(.headline)
                    Text(workout.startDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StatusBadge(state: workout.uploadState)
            }

            HStack(spacing: 12) {
                CompactMetricLabel(systemName: "timer", text: workout.duration.formattedDuration)

                if let distance = workout.totalDistanceMeters {
                    CompactMetricLabel(systemName: "map", text: distance.formattedDistance)
                }
            }

            if !workout.sentToIntervals {
                Button(workout.uploadState == .failed ? "Retry Upload" : "Upload Workout", action: onUpload)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canUpload || workout.uploadState == .uploading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct StatusBadge: View {
    let state: WorkoutModel.UploadState

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private var title: String {
        switch state {
        case .pending:
            return "Pending"
        case .uploading:
            return "Uploading"
        case .uploaded:
            return "Synced"
        case .failed:
            return "Failed"
        }
    }

    private var tint: Color {
        switch state {
        case .pending:
            return .orange
        case .uploading:
            return .blue
        case .uploaded:
            return .green
        case .failed:
            return .red
        }
    }
}

struct FilterChipButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(isSelected ? .blue : .gray.opacity(0.4))
    }
}

private struct CompactMetricLabel: View {
    let systemName: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemName)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

extension TimeInterval {
    var formattedDuration: String {
        let duration = Duration.seconds(self)
        return duration.formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1)))
    }
}

extension Double {
    var formattedDistance: String {
        let measurement = Measurement(value: self / 1000, unit: UnitLength.kilometers)
        return measurement.formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
