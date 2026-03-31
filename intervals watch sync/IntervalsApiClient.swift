//
//  IntervalsApiClient.swift
//  intervals watch sync
//
//  Created by Codex on 24/03/2026.
//

import Compression
import Foundation

enum IntervalsConfiguration {
    static let baseURL = URL(string: "https://intervals.icu/api/v1")!

    static var isConfigured: Bool {
        IntervalsSecretsStore.hasAPIKey()
    }
}

struct IntervalsActivityStream: Encodable {
    let type: String
    let name: String?
    let data: [Double?]

    init(type: String, name: String? = nil, data: [Double?]) {
        self.type = type
        self.name = name
        self.data = data
    }
}

struct IntervalsFetchedStream: Decodable {
    let type: String
    let name: String?
    let data: [Double?]
}

struct IntervalsUploadResponse: Decodable {
    struct ActivityReference: Decodable {
        let icuAthleteID: String?
        let id: String?

        enum CodingKeys: String, CodingKey {
            case icuAthleteID = "icu_athlete_id"
            case id
        }
    }

    let icuAthleteID: String?
    let id: String?
    let activities: [ActivityReference]?

    enum CodingKeys: String, CodingKey {
        case icuAthleteID = "icu_athlete_id"
        case id
        case activities
    }

    var primaryActivityID: String? {
        activities?.first?.id ?? id
    }
}

struct IntervalsListedActivity: Decodable {
    let id: String?
    let externalID: String?
    let deleted: Bool?
    let name: String?
    let type: String?
    let startDateLocal: String?

    enum CodingKeys: String, CodingKey {
        case id
        case externalID = "external_id"
        case deleted
        case name
        case type
        case startDateLocal = "start_date_local"
    }
}

struct IntervalsListedEvent: Decodable {
    let id: Int
    let category: String?
    let type: String?
    let name: String?
    let startDateLocal: String?
    let movingTime: Int?
    let loadTarget: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case category
        case type
        case name
        case startDateLocal = "start_date_local"
        case movingTime = "moving_time"
        case loadTarget = "load_target"
    }
}

struct IntervalsAPIStatusSnapshot {
    let checkedAt: Date
    let latencyMilliseconds: Int
    let athleteID: String
}

private struct IntervalsActivityUpdatePayload: Encodable {
    let type: String?
    let pairedEventID: Int?
    let perceivedExertion: Double?
    let sessionRPE: Int?

    var hasContent: Bool {
        type != nil || pairedEventID != nil || perceivedExertion != nil || sessionRPE != nil
    }

    enum CodingKeys: String, CodingKey {
        case type
        case pairedEventID = "paired_event_id"
        case perceivedExertion = "perceived_exertion"
        case sessionRPE = "session_rpe"
    }
}

final class IntervalsApiClient {
    enum ClientError: LocalizedError {
        case missingConfiguration
        case unreadableFile(URL)
        case invalidResponse
        case server(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                return "Save your Intervals.icu API key in the app before syncing."
            case .unreadableFile(let url):
                return "Could not read workout export file at \(url.lastPathComponent)."
            case .invalidResponse:
                return "Intervals.icu returned an unexpected response."
            case .server(let statusCode, let message):
                return "Intervals.icu upload failed (\(statusCode)): \(message)"
            }
        }
    }

    private let session: URLSession
    private let logger: IntervalsLogStore?
    private static let listDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .autoupdatingCurrent
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(session: URLSession = .shared, logger: IntervalsLogStore? = nil) {
        self.session = session
        self.logger = logger
    }

    func uploadWorkoutFile(_ filePath: String, params: [String: String]) async throws -> IntervalsUploadResponse {
        try await uploadWorkoutFile(URL(fileURLWithPath: filePath), params: params)
    }

    func uploadWorkoutFile(_ fileURL: URL, params: [String: String]) async throws -> IntervalsUploadResponse {
        guard IntervalsConfiguration.isConfigured else {
            throw ClientError.missingConfiguration
        }

        let fileData = try await readWorkoutFileData(from: fileURL)

        do {
            return try await uploadWorkoutPayload(
                fileName: fileURL.lastPathComponent,
                fileData: fileData,
                fileExtension: fileURL.pathExtension,
                params: params,
                summary: "Upload workout file \(fileURL.lastPathComponent)"
            )
        } catch ClientError.server(let statusCode, _) where statusCode == 413 {
            let gzippedData = try await gzipDetached(fileData)
            let gzippedFileName = "\(fileURL.deletingPathExtension().lastPathComponent).\(fileURL.pathExtension).gz"
            return try await uploadWorkoutPayload(
                fileName: gzippedFileName,
                fileData: gzippedData,
                fileExtension: "gz",
                params: params,
                summary: "Retry workout upload as gzip \(gzippedFileName)"
            )
        }
    }

    private func uploadWorkoutPayload(
        fileName: String,
        fileData: Data,
        fileExtension: String,
        params: [String: String],
        summary: String
    ) async throws -> IntervalsUploadResponse {
        var components = URLComponents(
            url: athleteActivitiesURL(),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = params
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }

        let boundary = "WorkoutBridge-\(UUID().uuidString)"
        var request = try makeRequest(url: components.url!, method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeMultipartBody(
            boundary: boundary,
            fileName: fileName,
            fileData: fileData,
            mimeType: mimeType(for: fileExtension)
        )

        let (data, httpResponse) = try await send(request, summary: summary)

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClientError.server(statusCode: httpResponse.statusCode, message: message)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(IntervalsUploadResponse.self, from: data)
        } catch {
            throw ClientError.server(
                statusCode: httpResponse.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Upload succeeded but response decoding failed."
            )
        }
    }

    private func readWorkoutFileData(from fileURL: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            guard let fileData = try? Data(contentsOf: fileURL) else {
                throw ClientError.unreadableFile(fileURL)
            }

            return fileData
        }
        .value
    }

    private func gzipDetached(_ data: Data) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Self.gzip(data)
        }
        .value
    }

    private static func gzip(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            return Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        }

        let destinationBufferSize = 64 * 1024
        var output = Data()

        try data.withUnsafeBytes { (sourceBuffer: UnsafeRawBufferPointer) in
            guard let sourceBaseAddress = sourceBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw ClientError.invalidResponse
            }

            let placeholderDestination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
            let placeholderSource = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
            defer {
                placeholderDestination.deallocate()
                placeholderSource.deallocate()
            }

            var stream = compression_stream(
                dst_ptr: placeholderDestination,
                dst_size: 0,
                src_ptr: UnsafePointer(placeholderSource),
                src_size: 0,
                state: nil
            )
            var status = compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
            guard status != COMPRESSION_STATUS_ERROR else {
                throw ClientError.invalidResponse
            }

            defer {
                compression_stream_destroy(&stream)
            }

            stream.src_ptr = sourceBaseAddress
            stream.src_size = data.count

            let header: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff]
            output.append(contentsOf: header)

            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationBufferSize)
            defer {
                destinationBuffer.deallocate()
            }

            repeat {
                stream.dst_ptr = destinationBuffer
                stream.dst_size = destinationBufferSize

                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else {
                    throw ClientError.invalidResponse
                }

                let produced = destinationBufferSize - stream.dst_size
                if produced > 0 {
                    output.append(destinationBuffer, count: produced)
                }
            } while status == COMPRESSION_STATUS_OK

            var crc = crc32(for: data)
            var inputSize = UInt32(truncatingIfNeeded: data.count)
            withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
            withUnsafeBytes(of: &inputSize) { output.append(contentsOf: $0) }
        }

        return output
    }

    private static func crc32(for data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff

        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xedb88320 & mask)
            }
        }

        return ~crc
    }

    func uploadWellness(_ record: WellnessRecord) async throws {
        try await uploadWellnessBulk([record])
    }

    func uploadWellnessBulk(_ records: [WellnessRecord]) async throws {
        guard IntervalsConfiguration.isConfigured else {
            throw ClientError.missingConfiguration
        }

        guard !records.isEmpty else {
            return
        }

        let url = athleteWellnessURL()
        var request = try makeRequest(url: url, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(records)

        let (data, httpResponse) = try await send(request, summary: "Upload wellness batch (\(records.count) day(s))")

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClientError.server(statusCode: httpResponse.statusCode, message: message)
        }

        // TODO: If you need more wellness endpoints later, add them here beside wellness-bulk.
    }

    func uploadActivityStreams(_ streams: [IntervalsActivityStream], activityID: String) async throws {
        guard IntervalsConfiguration.isConfigured else {
            throw ClientError.missingConfiguration
        }

        guard !streams.isEmpty else {
            return
        }

        let url = IntervalsConfiguration.baseURL.appending(path: "activity/\(activityID)/streams")
        var request = try makeRequest(url: url, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(streams)

        let (data, httpResponse) = try await send(
            request,
            summary: "Upload \(streams.count) extra activity stream(s) to \(activityID)"
        )

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClientError.server(statusCode: httpResponse.statusCode, message: message)
        }
    }

    func updateActivity(
        activityID: String,
        type: String? = nil,
        pairedEventID: Int? = nil,
        perceivedExertion: Double? = nil,
        sessionRPE: Int? = nil
    ) async throws {
        guard IntervalsConfiguration.isConfigured else {
            throw ClientError.missingConfiguration
        }

        let payload = IntervalsActivityUpdatePayload(
            type: type,
            pairedEventID: pairedEventID,
            perceivedExertion: perceivedExertion,
            sessionRPE: sessionRPE
        )
        guard payload.hasContent else {
            return
        }

        let url = IntervalsConfiguration.baseURL.appending(path: "activity/\(activityID)")
        var request = try makeRequest(url: url, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(payload)

        var updatedFields: [String] = []
        if let type {
            updatedFields.append("type=\(type)")
        }
        if let pairedEventID {
            updatedFields.append("paired_event_id=\(pairedEventID)")
        }
        if let perceivedExertion {
            updatedFields.append("perceived_exertion=\(perceivedExertion)")
        }
        if let sessionRPE {
            updatedFields.append("session_rpe=\(sessionRPE)")
        }

        let (data, httpResponse) = try await send(
            request,
            summary: "Update Intervals activity \(activityID) metadata (\(updatedFields.joined(separator: ", ")))"
        )

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClientError.server(statusCode: httpResponse.statusCode, message: message)
        }
    }

    func fetchActivityTimeStream(activityID: String) async throws -> [Double] {
        let streams = try await fetchActivityStreams(activityID: activityID, types: ["time"])
        let timeStream = streams.first(where: { $0.type == "time" || $0.name == "time" })
        return timeStream?.data.compactMap { $0 } ?? []
    }

    func fetchActivityStreams(activityID: String, types: [String]? = nil) async throws -> [IntervalsFetchedStream] {
        guard IntervalsConfiguration.isConfigured else {
            throw ClientError.missingConfiguration
        }

        var components = URLComponents(
            url: IntervalsConfiguration.baseURL.appending(path: "activity/\(activityID)/streams"),
            resolvingAgainstBaseURL: false
        )!
        if let types, !types.isEmpty {
            components.queryItems = [
                URLQueryItem(name: "types", value: types.joined(separator: ","))
            ]
        }

        let request = try makeRequest(url: components.url!, method: "GET")
        let summary = types?.isEmpty == false
            ? "Fetch activity streams for \(activityID) [\(types!.joined(separator: ", "))]"
            : "Fetch all activity streams for \(activityID)"
        let (data, httpResponse) = try await send(request, summary: summary)

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClientError.server(statusCode: httpResponse.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        return try decoder.decode([IntervalsFetchedStream].self, from: data)
    }

    func listEvents(
        oldest: Date,
        newest: Date,
        categories: [String]? = nil,
        limit: Int? = nil
    ) async throws -> [IntervalsListedEvent] {
        guard IntervalsConfiguration.isConfigured else {
            throw ClientError.missingConfiguration
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "oldest", value: Self.listDateFormatter.string(from: oldest)),
            URLQueryItem(name: "newest", value: Self.listDateFormatter.string(from: newest))
        ]
        if let categories, !categories.isEmpty {
            queryItems.append(
                URLQueryItem(name: "category", value: categories.joined(separator: ","))
            )
        }
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }

        var components = URLComponents(
            url: athleteEventsURL(),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = queryItems

        let request = try makeRequest(url: components.url!, method: "GET")
        let (data, httpResponse) = try await send(request, summary: "List Intervals calendar events")

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClientError.server(statusCode: httpResponse.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        return try decoder.decode([IntervalsListedEvent].self, from: data)
    }

    func listActivities(oldest: Date, newest: Date, limit: Int = 5000) async throws -> [IntervalsListedActivity] {
        guard IntervalsConfiguration.isConfigured else {
            throw ClientError.missingConfiguration
        }

        var components = URLComponents(
            url: athleteActivitiesURL(),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "oldest", value: Self.listDateFormatter.string(from: oldest)),
            URLQueryItem(name: "newest", value: Self.listDateFormatter.string(from: newest)),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        let request = try makeRequest(url: components.url!, method: "GET")
        let (data, httpResponse) = try await send(request, summary: "List Intervals activities")

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClientError.server(statusCode: httpResponse.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        return try decoder.decode([IntervalsListedActivity].self, from: data)
    }

    func deleteActivity(activityID: String) async throws {
        guard IntervalsConfiguration.isConfigured else {
            throw ClientError.missingConfiguration
        }

        let url = IntervalsConfiguration.baseURL.appending(path: "activity/\(activityID)")
        let request = try makeRequest(url: url, method: "DELETE")
        let (data, httpResponse) = try await send(request, summary: "Delete Intervals activity \(activityID)")

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClientError.server(statusCode: httpResponse.statusCode, message: message)
        }
    }

    func checkAPIStatus() async throws -> IntervalsAPIStatusSnapshot {
        guard IntervalsConfiguration.isConfigured else {
            throw ClientError.missingConfiguration
        }

        var components = URLComponents(
            url: athleteActivitiesURL(),
            resolvingAgainstBaseURL: false
        )!

        let now = Date()
        let oldest = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -7, to: now) ?? now
        components.queryItems = [
            URLQueryItem(name: "oldest", value: Self.listDateFormatter.string(from: oldest)),
            URLQueryItem(name: "newest", value: Self.listDateFormatter.string(from: now)),
            URLQueryItem(name: "limit", value: "1")
        ]

        let request = try makeRequest(url: components.url!, method: "GET")
        let startedAt = Date()
        let (_, httpResponse) = try await send(request, summary: "Check Intervals API status")
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ClientError.server(statusCode: httpResponse.statusCode, message: "Intervals status check failed.")
        }

        return IntervalsAPIStatusSnapshot(
            checkedAt: Date(),
            latencyMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1000),
            athleteID: AppSettingsStorage.normalizedAthleteID()
        )
    }

    private func makeRequest(url: URL, method: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue(try basicAuthorizationHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest, summary: String) async throws -> (Data, HTTPURLResponse) {
        let startedAt = Date()

        do {
            let (data, response) = try await session.data(for: request)
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger?.recordRequest(
                    method: request.httpMethod ?? "GET",
                    path: pathDescription(for: request.url),
                    summary: summary,
                    statusCode: nil,
                    durationMilliseconds: durationMilliseconds,
                    level: .error,
                    details: "Non-HTTP response received from Intervals."
                )
                throw ClientError.invalidResponse
            }

            logger?.recordRequest(
                method: request.httpMethod ?? "GET",
                path: pathDescription(for: request.url),
                summary: summary,
                statusCode: httpResponse.statusCode,
                durationMilliseconds: durationMilliseconds,
                level: (200...299).contains(httpResponse.statusCode) ? .success : .error,
                details: (200...299).contains(httpResponse.statusCode) ? nil : String(data: data, encoding: .utf8)
            )

            return (data, httpResponse)
        } catch {
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            let cancelled = Self.isCancellation(error)
            logger?.recordRequest(
                method: request.httpMethod ?? "GET",
                path: pathDescription(for: request.url),
                summary: summary,
                statusCode: nil,
                durationMilliseconds: durationMilliseconds,
                level: cancelled ? .info : .error,
                details: cancelled ? "Request cancelled locally." : error.localizedDescription
            )
            throw error
        }
    }

    private func pathDescription(for url: URL?) -> String {
        guard let url else {
            return "unknown"
        }

        if let query = url.query, !query.isEmpty {
            return "\(url.path)?\(query)"
        }

        return url.path
    }

    private func basicAuthorizationHeader() throws -> String {
        let apiKey = IntervalsSecretsStore.loadAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ClientError.missingConfiguration
        }

        let credentials = "API_KEY:\(apiKey)"
        let data = Data(credentials.utf8)
        return "Basic \(data.base64EncodedString())"
    }

    private func athleteActivitiesURL() -> URL {
        IntervalsConfiguration.baseURL.appending(path: "athlete/\(AppSettingsStorage.normalizedAthleteID())/activities")
    }

    private func athleteWellnessURL() -> URL {
        IntervalsConfiguration.baseURL.appending(path: "athlete/\(AppSettingsStorage.normalizedAthleteID())/wellness-bulk")
    }

    private func athleteEventsURL() -> URL {
        IntervalsConfiguration.baseURL.appending(path: "athlete/\(AppSettingsStorage.normalizedAthleteID())/events")
    }

    private func makeMultipartBody(boundary: String, fileName: String, fileData: Data, mimeType: String) -> Data {
        var body = Data()

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")

        return body
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "fit":
            return "application/octet-stream"
        case "tcx":
            return "application/vnd.garmin.tcx+xml"
        case "gpx":
            return "application/gpx+xml"
        case "gz":
            return "application/gzip"
        case "zip":
            return "application/zip"
        default:
            return "application/octet-stream"
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
