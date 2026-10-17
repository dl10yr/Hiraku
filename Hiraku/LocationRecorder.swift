import Foundation
import CoreLocation
import CoreMotion
import Combine
import OSLog

@MainActor
final class LocationRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var points: [TrackPoint] = []
    @Published private(set) var isRecording: Bool = false
    /// 現在検知されている状態（nil の場合は車・電車など記録対象外）
    @Published private(set) var detectedMode: TransportMode? = .walk
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let logger = Logger(subsystem: "Hiraku", category: "LocationRecorder")
    private let locationManager = CLLocationManager()
    private let activityManager = CMMotionActivityManager()
    private let pointStore: TrackPointStore
    private var currentSessionID = UUID()
    private var isAutomotiveMotion = false

    override init() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.pointStore = TrackPointStore(documentsDirectory: documentsDirectory)
        super.init()
        setupLocationManager()

        // 起動直後のメインスレッドブロック（真っ白画面）を防ぐため、非同期で過去ログを読み込む
        Task.detached(priority: .userInitiated) {
            let loadedPoints = TrackPointStore.loadSynchronously(from: documentsDirectory)
            let lastLoc = loadedPoints.last.map {
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
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.points.isEmpty {
                    self.points = loadedPoints
                } else {
                    self.points.insert(contentsOf: loadedPoints, at: 0)
                }
                if self.lastLocation == nil {
                    self.lastLocation = lastLoc
                }
            }
        }
    }

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5
        locationManager.activityType = .fitness
        locationManager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = locationManager.authorizationStatus
    }

    /// 初回起動時に位置情報・モーション権限をリクエストし、記録を開始
    /// 実機（iOS 13.4+）ではいきなり requestAlwaysAuthorization() を呼ぶとダイアログすら出ず無視される仕様のため、
    /// 必ず .notDetermined 時は requestWhenInUseAuthorization() を先に呼び、許可後に Always へ昇格させる
    func startOnLaunchIfNeeded() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            startRecording()
            locationManager.requestAlwaysAuthorization()
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
            locationManager.requestWhenInUseAuthorization()
            return
        }
        currentSessionID = UUID()
        #if os(iOS)
        // バックグラウンド位置情報更新は Always 権限がある場合のみ有効化する（WhenInUse のまま実機で true にするとエラーになるケースを防ぐ）
        if status == .authorizedAlways,
           let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
           backgroundModes.contains("location") {
            locationManager.allowsBackgroundLocationUpdates = true
        }
        locationManager.showsBackgroundLocationIndicator = true
        #endif
        locationManager.startUpdatingLocation()
        if let cached = locationManager.location {
            processLocation(cached)
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
            if activity.automotive {
                self.isAutomotiveMotion = true
                self.detectedMode = nil
            } else if activity.walking || activity.running {
                self.isAutomotiveMotion = false
                self.detectedMode = .walk
            } else if activity.cycling {
                self.isAutomotiveMotion = false
                self.detectedMode = .cycle
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            switch status {
            case .authorizedWhenInUse:
                if !self.isRecording {
                    self.startRecording()
                }
                // WhenInUse が許可されたら、バックグラウンド計測用に Always への昇格をリクエスト
                manager.requestAlwaysAuthorization()
            case .authorizedAlways:
                #if os(iOS)
                if let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
                   backgroundModes.contains("location") {
                    manager.allowsBackgroundLocationUpdates = true
                }
                #endif
                if !self.isRecording {
                    self.startRecording()
                }
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for location in locations {
                self.processLocation(location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if (error as NSError).code == CLError.locationUnknown.rawValue {
                return
            }
            self.logger.warning("Location manager error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func processLocation(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100 else { return }

        // 現在地表示用に lastLocation は常に更新する
        let previousLocation = lastLocation
        lastLocation = location

        // 徒歩または自転車と判定されたときだけ記録する（車・電車などはスキップ）
        guard let mode = classifyWalkOrCycle(for: location, previous: previousLocation) else {
            detectedMode = nil
            return
        }
        detectedMode = mode

        let newPoint = TrackPoint(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp,
            horizontalAccuracy: location.horizontalAccuracy,
            speed: max(0, location.speed),
            mode: mode,
            sessionID: currentSessionID
        )
        points.append(newPoint)
        Task {
            await pointStore.append(newPoint)
        }
    }

    /// 歩き（ランニング含む）または自転車ならその TransportMode を返し、車・電車などの高速移動時は nil を返す
    private func classifyWalkOrCycle(for location: CLLocation, previous: CLLocation?) -> TransportMode? {
        if isAutomotiveMotion {
            return nil
        }

        var speed = location.speed
        if speed < 0, let previous {
            let dt = location.timestamp.timeIntervalSince(previous.timestamp)
            let dist = location.distance(from: previous)
            if dt > 0, dist < 1_000 {
                speed = dist / dt
            }
        }

        // 秒速 8.5m (約 30.6 km/h) を超える場合は車や電車とみなして記録しない
        if speed > 8.5 {
            return nil
        }

        if speed >= 0 {
            if speed <= 2.8 {
                return .walk
            } else {
                return .cycle
            }
        }

        return detectedMode ?? .walk
    }
}
