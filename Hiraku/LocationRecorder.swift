import Foundation
import CoreLocation
import CoreMotion
import Combine
import OSLog

@MainActor
final class LocationRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var points: [TrackPoint] = []
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var currentMode: TransportMode = .walk
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let logger = Logger(subsystem: "Hiraku", category: "LocationRecorder")
    private let locationManager = CLLocationManager()
    private let activityManager = CMMotionActivityManager()
    private let pointStore: TrackPointStore
    private var currentSessionID = UUID()

    override init() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        // 前回のフォールバックで保存された東京駅ダミー座標 (35.6812, 139.7671) が残っていれば除外
        let loadedPoints = TrackPointStore.loadSynchronously(from: documentsDirectory).filter {
            !(abs($0.latitude - 35.6812) < 0.0001 && abs($0.longitude - 139.7671) < 0.0001)
        }
        self.pointStore = TrackPointStore(documentsDirectory: documentsDirectory)
        self.points = loadedPoints
        self.lastLocation = loadedPoints.last.map {
            CLLocation(
                coordinate: $0.coordinate,
                altitude: 0,
                horizontalAccuracy: $0.horizontalAccuracy,
                verticalAccuracy: -1,
                course: -1,
                speed: $0.speed,
                timestamp: $0.timestamp
            )
        }
        super.init()
        setupLocationManager()
        Task {
            await pointStore.bootstrapIfNeeded(with: points)
        }
    }

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5
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
        currentSessionID = UUID()
        #if os(iOS)
        if let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
           backgroundModes.contains("location") {
            locationManager.allowsBackgroundLocationUpdates = true
        }
        locationManager.showsBackgroundLocationIndicator = true
        #endif
        locationManager.startUpdatingLocation()
        if let cached = locationManager.location {
            Task { @MainActor in
                await self.processLocation(cached)
            }
        }
        startMotionTracking()
        isRecording = true
    }

    /// ワンタップで即座に計測停止
    func stopRecording() {
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        activityManager.stopActivityUpdates()
        isRecording = false
        Task {
            await pointStore.flush()
        }
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
            if status == .authorizedAlways || status == .authorizedWhenInUse, !self.isRecording {
                self.startRecording()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for location in locations {
                await self.processLocation(location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            // kCLError.locationUnknown (Code 0) は測位中（またはシミュレータのLocation=None時）の一時的な状態なので無視して測位継続
            if (error as NSError).code == CLError.locationUnknown.rawValue {
                return
            }
            self.logger.warning("Location manager error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func processLocation(_ location: CLLocation) async {
        guard shouldAccept(location) else { return }

        let inferredMode = classifyMode(for: location, previous: lastLocation)

        if let previousLocation = lastLocation {
            let deltaTime = location.timestamp.timeIntervalSince(previousLocation.timestamp)
            let distance = location.distance(from: previousLocation)
            if deltaTime > 20, distance > 150, distance < 30_000 {
                let averageSpeed = distance / deltaTime
                if averageSpeed > 2.8 && averageSpeed < 36.0 {
                    let gapMode = await recoverGapMode(from: previousLocation, to: location, fallback: inferredMode)
                    appendInterpolatedPoints(from: previousLocation, to: location, mode: gapMode)
                }
            }
        }

        let newPoint = TrackPoint(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp,
            horizontalAccuracy: location.horizontalAccuracy,
            speed: max(0, location.speed),
            mode: inferredMode,
            sessionID: currentSessionID
        )
        append(point: newPoint)
        lastLocation = location
    }

    private func shouldAccept(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0 else { return false }
        guard location.horizontalAccuracy <= 140 else { return false }

        guard let previousLocation = lastLocation else { return true }

        let distance = location.distance(from: previousLocation)

        // 精度が悪い（>65m）のに100m以上飛んだ場合のみ、基地局/Wi-Fiノイズとして除外する
        // （シミュレータのロケーション切り替えや高精度GPSでの移動は horizontalAccuracy が良いため受け入れる）
        if location.horizontalAccuracy > 65, distance > 100 {
            return false
        }

        if location.horizontalAccuracy > max(50, previousLocation.horizontalAccuracy * 2.5),
           distance > max(100, location.horizontalAccuracy * 1.8) {
            return false
        }

        return true
    }

    private func classifyMode(for location: CLLocation, previous: CLLocation?) -> TransportMode {
        var speed = location.speed
        if speed < 0, let previous {
            let deltaTime = location.timestamp.timeIntervalSince(previous.timestamp)
            if deltaTime > 0 {
                speed = location.distance(from: previous) / deltaTime
            }
        }

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

    private func recoverGapMode(from start: CLLocation, to end: CLLocation, fallback: TransportMode) async -> TransportMode {
        guard CMMotionActivityManager.isActivityAvailable() else { return fallback }

        return await withCheckedContinuation { continuation in
            activityManager.queryActivityStarting(from: start.timestamp, to: end.timestamp, to: .main) { [weak self] activities, error in
                Task { @MainActor in
                    if let error {
                        self?.logger.error("Failed to query motion history: \(error.localizedDescription, privacy: .public)")
                    }
                    let resolvedMode = self?.historicalMode(from: activities ?? [], between: start, and: end, fallback: fallback) ?? fallback
                    continuation.resume(returning: resolvedMode)
                }
            }
        }
    }

    private func historicalMode(
        from activities: [CMMotionActivity],
        between start: CLLocation,
        and end: CLLocation,
        fallback: TransportMode
    ) -> TransportMode {
        guard !activities.isEmpty else { return fallback }

        let averageSpeed = end.distance(from: start) / max(end.timestamp.timeIntervalSince(start.timestamp), 1)

        let walkingCount = activities.count { $0.walking || $0.running }
        let cyclingCount = activities.count { $0.cycling }
        let automotiveCount = activities.count { $0.automotive }

        if cyclingCount > max(walkingCount, automotiveCount) {
            return .cycle
        }

        if walkingCount > automotiveCount, averageSpeed < 3.5 {
            return .walk
        }

        if automotiveCount > 0 {
            return averageSpeed > 7.5 ? .transit : .vehicle
        }

        return fallback
    }

    private func appendInterpolatedPoints(from start: CLLocation, to end: CLLocation, mode: TransportMode) {
        let distance = end.distance(from: start)
        let deltaTime = end.timestamp.timeIntervalSince(start.timestamp)
        let averageSpeed = distance / max(deltaTime, 1)
        let stepCount = max(2, min(80, Int(distance / 60.0)))

        for step in 1..<stepCount {
            let ratio = Double(step) / Double(stepCount)
            let latitude = start.coordinate.latitude + (end.coordinate.latitude - start.coordinate.latitude) * ratio
            let longitude = start.coordinate.longitude + (end.coordinate.longitude - start.coordinate.longitude) * ratio

            let interpolatedPoint = TrackPoint(
                latitude: latitude,
                longitude: longitude,
                timestamp: start.timestamp.addingTimeInterval(deltaTime * ratio),
                horizontalAccuracy: min(start.horizontalAccuracy, end.horizontalAccuracy),
                speed: averageSpeed,
                mode: mode,
                isInterpolated: true,
                sessionID: currentSessionID
            )
            append(point: interpolatedPoint)
        }
    }

    private func append(point: TrackPoint) {
        points.append(point)
        Task {
            await pointStore.append(point)
        }
    }
}
