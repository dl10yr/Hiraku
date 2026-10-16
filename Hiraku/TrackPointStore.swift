import Foundation
import OSLog

actor TrackPointStore {
    private let logger = Logger(subsystem: "Hiraku", category: "TrackPointStore")
    private let storageURL: URL
    private let legacyStorageURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var pendingPoints: [TrackPoint] = []
    private var flushTask: Task<Void, Never>?

    init(documentsDirectory: URL) {
        self.storageURL = documentsDirectory.appendingPathComponent("track_points.jsonl")
        self.legacyStorageURL = documentsDirectory.appendingPathComponent("track_points.json")
    }

    nonisolated static func loadSynchronously(from documentsDirectory: URL) -> [TrackPoint] {
        let storageURL = documentsDirectory.appendingPathComponent("track_points.jsonl")
        let legacyStorageURL = documentsDirectory.appendingPathComponent("track_points.json")
        let decoder = JSONDecoder()

        if let data = try? Data(contentsOf: storageURL),
           let text = String(data: data, encoding: .utf8) {
            let points = text
                .split(whereSeparator: \.isNewline)
                .compactMap { line in
                    try? decoder.decode(TrackPoint.self, from: Data(line.utf8))
                }
            if !points.isEmpty {
                return points
            }
        }

        guard let data = try? Data(contentsOf: legacyStorageURL),
              let points = try? decoder.decode([TrackPoint].self, from: data) else {
            return []
        }
        return points
    }

    func append(_ point: TrackPoint) async {
        pendingPoints.append(point)
        if pendingPoints.count >= 12 {
            await flush()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                await self?.flush()
            }
        }
    }

    func bootstrapIfNeeded(with points: [TrackPoint]) async {
        guard !points.isEmpty else { return }
        guard !FileManager.default.fileExists(atPath: storageURL.path) else { return }
        pendingPoints.insert(contentsOf: points, at: 0)
        await flush()
    }

    func flush() async {
        guard !pendingPoints.isEmpty else {
            flushTask?.cancel()
            flushTask = nil
            return
        }

        let pointsToPersist = pendingPoints
        pendingPoints.removeAll(keepingCapacity: true)
        flushTask?.cancel()
        flushTask = nil

        do {
            try ensureStorageFile()
            let fileHandle = try FileHandle(forWritingTo: storageURL)
            defer {
                try? fileHandle.close()
            }
            try fileHandle.seekToEnd()

            for point in pointsToPersist {
                let data = try encoder.encode(point)
                try fileHandle.write(contentsOf: data)
                try fileHandle.write(contentsOf: Data([0x0A]))
            }
        } catch {
            pendingPoints.insert(contentsOf: pointsToPersist, at: 0)
            logger.error("Failed to flush track points: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureStorageFile() throws {
        if !FileManager.default.fileExists(atPath: storageURL.path) {
            try Data().write(to: storageURL, options: .atomic)
        }
    }
}
