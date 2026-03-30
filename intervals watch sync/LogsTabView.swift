//
//  LogsTabView.swift
//  intervals watch sync
//
//  Created by Codex on 27/03/2026.
//

import SwiftUI

private enum LogFilter: String, CaseIterable, Identifiable {
    case all
    case errors
    case success

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .errors:
            return "Errors"
        case .success:
            return "Success"
        }
    }
}

struct LogsTabView: View {
    @ObservedObject var healthKitManager: HealthKitManager
    @ObservedObject var intervalsLogStore: IntervalsLogStore

    let onShowSettings: () -> Void

    @State private var logFilter: LogFilter = .all

    var body: some View {
        NavigationStack {
            List {
                statusSection
                filterSection
                logsSection
            }
            .navigationTitle("Logs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        intervalsLogStore.clear()
                    }
                    .disabled(intervalsLogStore.entries.isEmpty)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onShowSettings) {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
        }
    }

    private var statusSection: some View {
        Section("API Status") {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)

                VStack(alignment: .leading, spacing: 4) {
                    Text(healthKitManager.intervalsAPIStatusMessage)
                        .font(.subheadline.weight(.semibold))

                    if let checkedAt = healthKitManager.intervalsAPIStatusCheckedAt {
                        Text("Checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
            .disabled(healthKitManager.isCheckingIntervalsAPIStatus)
        }
    }

    private var filterSection: some View {
        Section("Filters") {
            Picker("Entries", selection: $logFilter) {
                ForEach(LogFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            Text("Every Intervals request made by the app is logged here with method, endpoint, status code, and latency.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var logsSection: some View {
        Section("Intervals API Logs") {
            if filteredLogs.isEmpty {
                ContentUnavailableView(
                    "No logs yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Ping the API or sync a workout and this screen will start gossiping.")
                )
                .padding(.vertical, 12)
            } else {
                ForEach(filteredLogs) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: iconName(for: entry.level))
                                .foregroundStyle(color(for: entry.level))
                                .font(.subheadline.weight(.semibold))

                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.summary)
                                    .font(.subheadline.weight(.semibold))

                                Text("\(entry.method) \(entry.path)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 10) {
                                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    if let statusCode = entry.statusCode {
                                        Text("HTTP \(statusCode)")
                                    }
                                    if let durationMilliseconds = entry.durationMilliseconds {
                                        Text("\(durationMilliseconds) ms")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                if let details = entry.details {
                                    Text(details)
                                        .font(.caption)
                                        .foregroundStyle(entry.level == .error ? .red : .secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var filteredLogs: [IntervalsLogEntry] {
        switch logFilter {
        case .all:
            return intervalsLogStore.entries
        case .errors:
            return intervalsLogStore.entries.filter { $0.level == .error }
        case .success:
            return intervalsLogStore.entries.filter { $0.level == .success }
        }
    }

    private var statusColor: Color {
        switch healthKitManager.intervalsAPIStatusHealthy {
        case .some(true):
            return .green
        case .some(false):
            return .red
        case .none:
            return .gray
        }
    }

    private func color(for level: IntervalsLogEntry.Level) -> Color {
        switch level {
        case .info:
            return .blue
        case .success:
            return .green
        case .error:
            return .red
        }
    }

    private func iconName(for level: IntervalsLogEntry.Level) -> String {
        switch level {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }
}
