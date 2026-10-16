import Foundation
import CoreLocation

nonisolated enum TransportMode: String, Codable, CaseIterable, Sendable {
    case walk
    case cycle
    case transit
    case vehicle
    case unknown

    var label: String {
        switch self {
        case .walk: "徒歩"
        case .cycle: "自転車"
        case .transit: "電車・地下鉄"
        case .vehicle: "車・乗り物"
        case .unknown: "不明"
        }
    }

    var systemImage: String {
        switch self {
        case .walk: "figure.walk"
        case .cycle: "bicycle"
        case .transit: "tram.fill"
        case .vehicle: "car.fill"
        case .unknown: "location.fill"
        }
    }

    var isWalking: Bool {
        self == .walk
    }
}

nonisolated enum RevealFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "すべて"
    case walkOnly = "徒歩のみ"

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
    var isInterpolated: Bool = false
    /// 開始〜停止までの1回の計測セッションID（過去データでnilの場合は時間ギャップで自動分割）
    var sessionID: UUID? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// この地点で開かれる雲の半径（メートル）
    var revealRadius: CLLocationDistance {
        switch mode {
        case .walk: 45
        case .cycle: 60
        case .transit, .vehicle: 80
        case .unknown: 45
        }
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
        var currentPoints: [TrackPoint] = []
        var currentID = sorted[0].sessionID ?? sorted[0].id

        for pt in sorted {
            if let prev = currentPoints.last {
                let sessionChanged: Bool = {
                    if let s1 = prev.sessionID, let s2 = pt.sessionID {
                        return s1 != s2
                    }
                    if prev.sessionID != nil || pt.sessionID != nil {
                        return true
                    }
                    // sessionID が無い旧データは 15分以上の空白で別セッションとみなす
                    return pt.timestamp.timeIntervalSince(prev.timestamp) > 900
                }()

                if sessionChanged {
                    sessions.append(TrackSession(id: currentID, points: currentPoints))
                    currentPoints = [pt]
                    currentID = pt.sessionID ?? pt.id
                } else {
                    currentPoints.append(pt)
                }
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
