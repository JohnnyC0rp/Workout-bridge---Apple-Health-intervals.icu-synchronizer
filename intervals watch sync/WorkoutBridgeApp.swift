//
//  WorkoutBridgeApp.swift
//  intervals watch sync
//
//  Created by Codex on 24/03/2026.
//

import SwiftUI

@main
struct WorkoutBridgeApp: App {
    @StateObject private var appSettings: AppSettings
    @StateObject private var workoutStore: WorkoutStore
    @StateObject private var healthKitManager: HealthKitManager
    @StateObject private var appIconManager: AppIconManager
    @StateObject private var intervalsLogStore: IntervalsLogStore

    init() {
        let settings = AppSettings()
        let store = WorkoutStore(loadImmediately: false)
        let logStore = IntervalsLogStore(loadImmediately: false)
        let apiClient = IntervalsApiClient(logger: logStore)
        let iconManager = AppIconManager()
        let manager = HealthKitManager(
            workoutStore: store,
            apiClient: apiClient,
            settings: settings
        )

        _appSettings = StateObject(wrappedValue: settings)
        _workoutStore = StateObject(wrappedValue: store)
        _healthKitManager = StateObject(wrappedValue: manager)
        _appIconManager = StateObject(wrappedValue: iconManager)
        _intervalsLogStore = StateObject(wrappedValue: logStore)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                appSettings: appSettings,
                appIconManager: appIconManager,
                healthKitManager: healthKitManager,
                workoutStore: workoutStore,
                intervalsLogStore: intervalsLogStore
            )
        }
    }
}
