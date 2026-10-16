import Foundation
import CoreLocation
import CoreMotion
import Observation

@Observable
@MainActor
final class LocationRecorder: NSObject, CLLocationManagerDelegate {
    private(set) var points: [TrackPoint] = []
    private(set) var isRecording: Bool = false
    private(set) var currentMode: TransportMode = .walk
    private(set) var lastLocation: CLLocation?
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let locationManager = CLLocationManager()
    private let activityManager = CMMotionActivityManager()
    private let storageURL: URL

    override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.storageURL = docs.appendingPathComponent("track_points.json")
        super.init()
        loadPoints()
        setupLocationManager()
    }

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 8
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = locationManager.authorizationStatus
    }

    /// 初回起動時に位置情報・モーション権限をリクエストし、記録を開始
    func startOnLaunchIfNeeded() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
            startRecording()
        case .authorizedAlways:
            startRecording()
        default:
            break
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard !isRecording else { return }
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            locationManager.requestAlwaysAuthorization()
            return
        }
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()
        startMotionTracking()
        isRecording = true
    }

    /// ワンタップで即座に計測停止
    func stopRecording() {
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        activityManager.stopActivityUpdates()
        isRecording = false
        savePoints()
    }

    private func startMotionTracking() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            if activity.walking || activity.running {
                self.currentMode = .walk
            } else if activity.cycling {
                self.currentMode = .cycle
            } else if activity.automotive {
                self.currentMode = .vehicle
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                if !self.isRecording {
                    self.startRecording()
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for loc in locations {
                processLocation(loc)
            }
        }
    }

    private func processLocation(_ location: CLLocation) {
        // 精度が悪すぎるノイズ（地下鉄の基地局ジャンプなど）は除外
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 120 else { return }

        let inferredMode = classifyMode(for: location, previous: lastLocation)

        // 地下鉄・トンネル対策: 前回地点から時間が空き、かつ一定距離ワープしていたら直線補間して雲を繋げる
        if let prev = lastLocation {
            let dt = location.timestamp.timeIntervalSince(prev.timestamp)
            let dist = location.distance(from: prev)
            if dt > 20, dist > 150, dist < 30_000 {
                let avgSpeed = dist / dt // m/s
                // 地下鉄相当の速度 (約10km/h〜130km/h) なら地上復帰時に間のルートを補間
                if avgSpeed > 2.8 && avgSpeed < 36.0 {
                    let steps = max(2, min(80, Int(dist / 60.0)))
                    for i in 1..<steps {
                        let ratio = Double(i) / Double(steps)
                        let lat = prev.coordinate.latitude + (location.coordinate.latitude - prev.coordinate.latitude) * ratio
                        let lon = prev.coordinate.longitude + (location.coordinate.longitude - prev.coordinate.longitude) * ratio
                        let interpPoint = TrackPoint(
                            latitude: lat,
                            longitude: lon,
                            timestamp: prev.timestamp.addingTimeInterval(dt * ratio),
                            horizontalAccuracy: location.horizontalAccuracy,
                            speed: avgSpeed,
                            mode: .transit,
                            isInterpolated: true
                        )
                        points.append(interpPoint)
                    }
                }
            }
        }

        let newPoint = TrackPoint(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp,
            horizontalAccuracy: location.horizontalAccuracy,
            speed: max(0, location.speed),
            mode: inferredMode
        )
        points.append(newPoint)
        lastLocation = location
        savePoints()
    }

    private func classifyMode(for location: CLLocation, previous: CLLocation?) -> TransportMode {
        var speed = location.speed
        if speed < 0, let prev = previous {
            let dt = location.timestamp.timeIntervalSince(prev.timestamp)
            if dt > 0 {
                speed = location.distance(from: prev) / dt
            }
        }
        // CoreMotionの判定と移動速度を組み合わせる
        if currentMode == .walk && speed < 3.2 {
            return .walk
        }
        if speed >= 0 {
            if speed < 2.2 { return .walk }
            if speed < 6.5 { return currentMode == .walk ? .walk : .cycle }
            return currentMode == .vehicle ? .vehicle : .transit
        }
        return currentMode
    }

    // MARK: - Persistence

    private func loadPoints() {
        guard let data = try? Data(contentsOf: storageURL),
              let saved = try? JSONDecoder().decode([TrackPoint].self, from: data) else { return }
        self.points = saved
    }

    private func savePoints() {
        guard let data = try? JSONEncoder().encode(points) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
