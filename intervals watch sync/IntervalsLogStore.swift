//
//  IntervalsLogStore.swift
//  intervals watch sync
//
//  Created by Codex on 27/03/2026.
//

import Combine
import Foundation

struct IntervalsLogEntry: Codable, Identifiable, Equatable, Sendable {
    enum Level: String, Codable {
        case info
        case success
        case error
    }

    let id: UUID
    let timestamp: Date
    let method: String
    let path: String
    let summary: String
    let statusCode: Int?
    let durationMilliseconds: Int?
    let level: Level
    let details: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        method: String,
        path: String,
        summary: String,
        statusCode: Int? = nil,
        durationMilliseconds: Int? = nil,
        level: Level,
        details: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.summary = summary
        self.statusCode = statusCode
        self.durationMilliseconds = durationMilliseconds
        self.level = level
        self.details = details
    }
}

@MainActor
final class IntervalsLogStore: ObservableObject {
    @Published private(set) var entries: [IntervalsLogEntry] = []

    private let fileManager: FileManager
    private let storageURL: URL
    private let maximumEntries = 250
    private let saveQueue = DispatchQueue(label: "com.johnnycorp.intervals-watch-sync.intervals-log-save", qos: .utility)
    private var hasLoadedFromDisk = false

    init(fileManager: FileManager = .default, loadImmediately: Bool = true) {
        self.fileManager = fileManager

        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.storageURL = supportDirectory
            .appendingPathComponent("WorkoutBridge", isDirectory: true)
            .appendingPathComponent("intervals-api-logs.json", isDirectory: false)

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
        let loadedEntries = await Task.detached(priority: .utility) {
            try? Self.loadEntries(from: storageURL)
        }
        .value

        if let loadedEntries {
            entries = loadedEntries
        }
    }

    func recordRequest(
        method: String,
        path: String,
        summary: String,
        statusCode: Int?,
        durationMilliseconds: Int?,
        level: IntervalsLogEntry.Level,
        details: String? = nil
    ) {
        append(
            IntervalsLogEntry(
                method: method,
                path: path,
                summary: summary,
                statusCode: statusCode,
                durationMilliseconds: durationMilliseconds,
                level: level,
                details: trimmedDetails(details)
            )
        )
    }

    func recordInfo(summary: String, details: String? = nil) {
        append(
            IntervalsLogEntry(
                method: "INFO",
                path: "local",
                summary: summary,
                level: .info,
                details: trimmedDetails(details)
            )
        )
    }

    func clear() {
        entries = []
        save()
    }

    private func append(_ entry: IntervalsLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maximumEntries {
            entries = Array(entries.prefix(maximumEntries))
        }
        save()
    }

    private func trimmedDetails(_ details: String?) -> String? {
        guard let details else {
            return nil
        }

        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return String(trimmed.prefix(280))
    }

    private func save() {
        let entries = entries
        let storageURL = storageURL

        saveQueue.async {
            do {
                try Self.writeEntries(entries, to: storageURL)
            } catch {
                print("IntervalsLogStore save failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func loadEntries(from storageURL: URL) throws -> [IntervalsLogEntry] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return []
        }

        let data = try Data(contentsOf: storageURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([IntervalsLogEntry].self, from: data)
    }

    nonisolated private static func writeEntries(_ entries: [IntervalsLogEntry], to storageURL: URL) throws {
        let directoryURL = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(entries)
        // Keeping the logs in one small file makes debugging easy and drama low.
        try data.write(to: storageURL, options: .atomic)
    }
}
