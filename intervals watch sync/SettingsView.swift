//
//  SettingsView.swift
//  intervals watch sync
//
//  Created by Codex on 27/03/2026.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var appSettings: AppSettings
    @ObservedObject var appIconManager: AppIconManager
    @ObservedObject var healthKitManager: HealthKitManager

    @Binding var apiKeyConfigured: Bool

    @State private var apiKeyDraft = ""
    @State private var apiKeyMessage: String?
    @State private var selectedWellnessDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                wellnessSection
                advancedStreamsSection
                appIconSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                refreshStoredAPIKey()
                appIconManager.refreshSelection()
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            statusRow(
                title: "HealthKit",
                value: healthKitManager.authorizationState.title,
                tint: healthKitTint
            )

            statusRow(
                title: "Intervals.icu API",
                value: apiKeyConfigured ? "Configured" : "Missing API key",
                tint: apiKeyConfigured ? .green : .orange
            )

            statusRow(
                title: "Background delivery",
                value: healthKitManager.backgroundDeliveryEnabled ? "Enabled" : "Not enabled yet",
                tint: healthKitManager.backgroundDeliveryEnabled ? .green : .secondary
            )

            statusRow(
                title: "Automatic uploads",
                value: appSettings.automaticUploadsEnabled ? "On" : "Off",
                tint: appSettings.automaticUploadsEnabled ? .green : .orange
            )

            if let lastSyncError = healthKitManager.lastSyncError {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last error")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(lastSyncError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                .padding(.vertical, 4)
            }

            Text(healthKitManager.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)

            SecureField("Intervals API key", text: $apiKeyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()

            HStack {
                Button(apiKeyConfigured ? "Update API Key" : "Save API Key") {
                    saveAPIKey()
                }

                Button("Clear Saved Key", role: .destructive) {
                    clearAPIKey()
                }
                .disabled(!apiKeyConfigured)
            }

            TextField("Athlete ID (0 means me)", text: $appSettings.athleteID)
                .textInputAutocapitalization(.never)
                .keyboardType(.numbersAndPunctuation)

            Toggle("Automatic uploads for new workouts and wellness", isOn: $appSettings.automaticUploadsEnabled)

            Text(appSettings.automaticUploadsStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("API key is saved locally in this iPhone's Keychain. Athlete ID and sync preferences stay in on-device app settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let apiKeyMessage {
                Text(apiKeyMessage)
                    .font(.caption)
                    .foregroundStyle(apiKeyConfigured ? .green : .secondary)
            }

            Button("Check Intervals API Status") {
                Task {
                    await healthKitManager.checkIntervalsAPIStatus()
                }
            }
            .disabled(healthKitManager.isCheckingIntervalsAPIStatus)

            Button("Request Health Access") {
                Task {
                    await healthKitManager.requestAuthorization()
                }
            }
            .disabled(healthKitManager.authorizationState == .ready || healthKitManager.isSyncing)

            Button("Force Sync / Refresh Workout List") {
                Task {
                    await healthKitManager.forceSync()
                }
            }
            .disabled(healthKitManager.isSyncing)
        }
    }

    private var wellnessSection: some View {
        Section("Wellness") {
            Text("Manual wellness upload sends every clean Apple Health overlap we currently support for the selected day: weight, body fat, resting HR, HRV SDNN, VO2max, steps, sleep duration, sleep-stage summary in comments, average sleeping HR, oxygen saturation, respiratory rate, blood pressure, blood glucose, water intake, calories, and macros.")
                .font(.caption)
                .foregroundStyle(.secondary)

            DatePicker(
                "Wellness date",
                selection: $selectedWellnessDate,
                displayedComponents: .date
            )

            Button("Upload Selected Wellness Day") {
                Task {
                    await healthKitManager.uploadWellnessManually(for: selectedWellnessDate)
                }
            }
            .disabled(!canTalkToIntervals || healthKitManager.isSyncing)

            Text(healthKitManager.lastWellnessStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advancedStreamsSection: some View {
        Section("Advanced Streams") {
            Text("Advanced streams are optional extra Intervals data columns for metrics the workout file does not map automatically. Normal workout data like heart rate, distance, pace, GPS, cadence, and power already go through the TCX upload; use these fields only for extras like ground contact time, vertical oscillation, or flights climbed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("If you leave these blank, Workout Bridge uses `GroundContactTime` and `VerticalOscillation` as defaults. Flights climbed stays optional.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Recommended Intervals setup: `GroundContactTime` -> record field `stance_time` with units `ms`, and `VerticalOscillation` -> record field `vertical_oscillation` with units `mm`.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(IntervalsExtraStreamSetting.allCases) { setting in
                VStack(alignment: .leading, spacing: 6) {
                    TextField(
                        setting.placeholder,
                        text: Binding(
                            get: { appSettings.customStreamCode(for: setting) },
                            set: { appSettings.setCustomStreamCode($0, for: setting) }
                        ),
                        prompt: Text(setting.title)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Text("Effective code: \(appSettings.effectiveCustomStreamCode(for: setting) ?? "Not configured")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(setting.helpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var appIconSection: some View {
        AppIconSectionView(appIconManager: appIconManager)
    }

    private var canTalkToIntervals: Bool {
        apiKeyConfigured && healthKitManager.authorizationState == .ready
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
            return .secondary
        }
    }

    @ViewBuilder
    private func statusRow(title: String, value: String, tint: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
        }
    }

    private func refreshStoredAPIKey() {
        let storedKey = IntervalsSecretsStore.loadAPIKey()
        apiKeyDraft = storedKey
        apiKeyConfigured = !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveAPIKey() {
        do {
            try IntervalsSecretsStore.saveAPIKey(apiKeyDraft)
            refreshStoredAPIKey()
            apiKeyMessage = apiKeyConfigured ? "API key saved locally." : "API key removed."
        } catch {
            apiKeyMessage = error.localizedDescription
        }
    }

    private func clearAPIKey() {
        do {
            try IntervalsSecretsStore.deleteAPIKey()
            refreshStoredAPIKey()
            apiKeyMessage = "Saved API key removed."
        } catch {
            apiKeyMessage = error.localizedDescription
        }
    }
}
