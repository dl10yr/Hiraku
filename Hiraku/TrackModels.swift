import Foundation
import CoreLocation

nonisolated enum TransportMode: String, Codable, CaseIterable, Sendable {
    case walk
    case cycle

    var label: String {
        switch self {
        case .walk: "徒歩"
        case .cycle: "自転車"
        }
    }

    var systemImage: String {
        switch self {
        case .walk: "figure.walk"
        case .cycle: "bicycle"
        }
    }
}

nonisolated enum RouteFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "すべて"
    case walkOnly = "徒歩のみ"
    case cycleOnly = "自転車のみ"

    var id: String { rawValue }
}

nonisolated struct TrackPoint: Identifiable, Codable, Sendable, Hashable {
    var id: UUID = UUID()
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let horizontalAccuracy: Double
    let speed: Double
    var mode: TransportMode
    var sessionID: UUID

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// 連続して記録されたルートの1本のライン（徒歩または自転車）
nonisolated struct RouteSegment: Identifiable, Sendable {
    let id: UUID
    let mode: TransportMode
    let coordinates: [CLLocationCoordinate2D]

    /// ポイント配列から、セッション切れや時間・距離の空白（3分または200m以上）で分割したライン群を生成
    static func buildSegments(from points: [TrackPoint]) -> [RouteSegment] {
        guard !points.isEmpty else { return [] }
        let sorted = points.sorted { $0.timestamp < $1.timestamp }

        var segments: [RouteSegment] = []
        var currentCoords: [CLLocationCoordinate2D] = [sorted[0].coordinate]
        var currentMode = sorted[0].mode
        var prevPoint = sorted[0]

        for pt in sorted.dropFirst() {
            let dt = pt.timestamp.timeIntervalSince(prevPoint.timestamp)
            let dist = CLLocation(latitude: pt.latitude, longitude: pt.longitude)
                .distance(from: CLLocation(latitude: prevPoint.latitude, longitude: prevPoint.longitude))

            let shouldSplit = pt.sessionID != prevPoint.sessionID || dt > 180 || dist > 200 || pt.mode != currentMode

            if shouldSplit {
                if currentCoords.count >= 2 {
                    segments.append(RouteSegment(id: UUID(), mode: currentMode, coordinates: currentCoords))
                }
                currentCoords = [pt.coordinate]
                currentMode = pt.mode
            } else {
                currentCoords.append(pt.coordinate)
            }
            prevPoint = pt
        }

        if currentCoords.count >= 2 {
            segments.append(RouteSegment(id: UUID(), mode: currentMode, coordinates: currentCoords))
        }

        return segments
    }
}

/// 1回分の計測履歴セッション
nonisolated struct TrackSession: Identifiable, Hashable, Sendable {
    let id: UUID
    let points: [TrackPoint]

    var startDate: Date {
        points.first?.timestamp ?? Date()
    }

    var endDate: Date {
        points.last?.timestamp ?? startDate
    }

    var duration: TimeInterval {
        max(0, endDate.timeIntervalSince(startDate))
    }

    var totalDistance: CLLocationDistance {
        guard points.count > 1 else { return 0 }
        var total: CLLocationDistance = 0
        for i in 1..<points.count {
            let p1 = CLLocation(latitude: points[i - 1].latitude, longitude: points[i - 1].longitude)
            let p2 = CLLocation(latitude: points[i].latitude, longitude: points[i].longitude)
            total += p2.distance(from: p1)
        }
        return total
    }

    var primaryMode: TransportMode {
        var counts: [TransportMode: Int] = [:]
        for pt in points {
            counts[pt.mode, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? .walk
    }

    /// 蓄積された全ポイントから計測セッション一覧を生成（新しい順）
    static func buildSessions(from allPoints: [TrackPoint]) -> [TrackSession] {
        guard !allPoints.isEmpty else { return [] }
        let sorted = allPoints.sorted { $0.timestamp < $1.timestamp }

        var sessions: [TrackSession] = []
        var currentPoints: [TrackPoint] = [sorted[0]]
        var currentID = sorted[0].sessionID

        for pt in sorted.dropFirst() {
            if pt.sessionID != currentID {
                sessions.append(TrackSession(id: currentID, points: currentPoints))
                currentPoints = [pt]
                currentID = pt.sessionID
            } else {
                currentPoints.append(pt)
            }
        }

        if !currentPoints.isEmpty {
            sessions.append(TrackSession(id: currentID, points: currentPoints))
        }

        return sessions.reversed()
    }
}
