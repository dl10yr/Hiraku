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

    var isWalking: Bool {
        self == .walk
    }
}

nonisolated enum RevealFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "すべて"
    case walkOnly = "徒歩のみ"

    var id: String { rawValue }
}

nonisolated struct TrackPoint: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let horizontalAccuracy: Double
    let speed: Double
    var mode: TransportMode
    var isInterpolated: Bool = false

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
