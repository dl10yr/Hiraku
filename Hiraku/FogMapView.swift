import SwiftUI
import MapKit

/// OpenStreetMap タイルオーバーレイ（User-Agent ヘッダ付与）
nonisolated final class OSMTileOverlay: MKTileOverlay {
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "Hiraku/1.0 (com.dl10yr.hiraku; iOS OSM FogMap)"]
        return URLSession(configuration: config)
    }()

    init() {
        super.init(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        // Apple Maps のベクター描画を完全に消すと、タイル読み込み前やオフライン時に画面が真っ暗になるため false にする
        self.canReplaceMapContent = false
        self.minimumZ = 2
        self.maximumZ = 19
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let url = self.url(forTilePath: path)
        session.dataTask(with: url) { data, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result(nil, error)
                return
            }
            result(data, error)
        }.resume()
    }
}

nonisolated private struct SpatialPointIndex {
    private struct Cell: Hashable {
        let latitudeBucket: Int
        let longitudeBucket: Int
    }

    private let cellSizeDegrees: Double = 0.002
    private var buckets: [Cell: [TrackPoint]] = [:]

    init(points: [TrackPoint]) {
        rebuild(with: points)
    }

    mutating func rebuild(with points: [TrackPoint]) {
        buckets.removeAll(keepingCapacity: true)
        for point in points {
            buckets[cell(for: point.coordinate), default: []].append(point)
        }
    }

    func points(in mapRect: MKMapRect, paddingMeters: CLLocationDistance) -> [TrackPoint] {
        let topLeft = MKMapPoint(x: mapRect.minX, y: mapRect.minY).coordinate
        let bottomRight = MKMapPoint(x: mapRect.maxX, y: mapRect.maxY).coordinate

        let centerLatitude = (topLeft.latitude + bottomRight.latitude) / 2
        let latitudePadding = paddingMeters / 111_000
        let longitudeScale = max(0.2, cos(centerLatitude * .pi / 180))
        let longitudePadding = paddingMeters / (111_000 * longitudeScale)

        let minLatitude = min(topLeft.latitude, bottomRight.latitude) - latitudePadding
        let maxLatitude = max(topLeft.latitude, bottomRight.latitude) + latitudePadding
        let minLongitude = min(topLeft.longitude, bottomRight.longitude) - longitudePadding
        let maxLongitude = max(topLeft.longitude, bottomRight.longitude) + longitudePadding

        let minLatBucket = bucketIndex(for: minLatitude)
        let maxLatBucket = bucketIndex(for: maxLatitude)
        let minLonBucket = bucketIndex(for: minLongitude)
        let maxLonBucket = bucketIndex(for: maxLongitude)

        // ズームアウトしすぎてセル数が膨大な場合は全探索にフォールバック（ハング防止）
        let latSpan = maxLatBucket - minLatBucket + 1
        let lonSpan = maxLonBucket - minLonBucket + 1
        if latSpan <= 0 || lonSpan <= 0 || latSpan * lonSpan > 2_500 {
            return buckets.values.flatMap { $0 }.sorted { $0.timestamp < $1.timestamp }
        }

        var result: [TrackPoint] = []
        result.reserveCapacity(min(512, latSpan * lonSpan * 4))

        for latitudeBucket in minLatBucket...maxLatBucket {
            for longitudeBucket in minLonBucket...maxLonBucket {
                let cell = Cell(latitudeBucket: latitudeBucket, longitudeBucket: longitudeBucket)
                if let bucketPoints = buckets[cell] {
                    result.append(contentsOf: bucketPoints)
                }
            }
        }

        return result.sorted { $0.timestamp < $1.timestamp }
    }

    private func cell(for coordinate: CLLocationCoordinate2D) -> Cell {
        Cell(
            latitudeBucket: bucketIndex(for: coordinate.latitude),
            longitudeBucket: bucketIndex(for: coordinate.longitude)
        )
    }

    private func bucketIndex(for value: Double) -> Int {
        Int(floor(value / cellSizeDegrees))
    }
}

/// 地図全体を覆う「雲（霧）」のオーバーレイ
nonisolated final class FogOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world

    private let lock = NSLock()
    private var _points: [TrackPoint]
    private var pointIndex: SpatialPointIndex

    var points: [TrackPoint] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _points
        }
        set {
            lock.lock()
            _points = newValue
            pointIndex.rebuild(with: newValue)
            lock.unlock()
        }
    }

    init(points: [TrackPoint]) {
        self._points = points
        self.pointIndex = SpatialPointIndex(points: points)
    }

    func visiblePoints(in mapRect: MKMapRect, paddingMeters: CLLocationDistance) -> [TrackPoint] {
        lock.lock()
        defer { lock.unlock() }
        return pointIndex.points(in: mapRect, paddingMeters: paddingMeters)
    }
}

/// 訪れた場所だけ雲をくり抜くレンダラー（MapKit のバックグラウンド描画スレッドで動作するため nonisolated）
nonisolated final class FogOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let fogOverlay = overlay as? FogOverlay else { return }

        let rect = self.rect(for: mapRect)
        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        // 1. 雲（半透明の白霧〜スモーク）で地図を覆う（うっすら下の地形が見える程度にして「真っ黒で何も表示されない」を防ぐ）
        context.setFillColor(UIColor(red: 0.12, green: 0.15, blue: 0.20, alpha: 0.68).cgColor)
        context.fill(rect)

        let visiblePoints = fogOverlay.visiblePoints(in: mapRect, paddingMeters: 420)
        guard !visiblePoints.isEmpty else {
            context.restoreGState()
            return
        }

        // 2. 訪れた座標と移動軌跡の雲をくり抜く
        context.setBlendMode(.clear)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // 各ポイントの半径分しっかり円形にくり抜く + 近接するポイント間を太い線で繋ぐ
        for (index, point) in visiblePoints.enumerated() {
            let mapPoint = MKMapPoint(point.coordinate)
            let radiusInMapPoints = point.revealRadius * MKMapPointsPerMeterAtLatitude(point.latitude)
            let pointMapRect = MKMapRect(
                x: mapPoint.x - radiusInMapPoints,
                y: mapPoint.y - radiusInMapPoints,
                width: radiusInMapPoints * 2,
                height: radiusInMapPoints * 2
            )
            let drawRect = self.rect(for: pointMapRect)
            context.fillEllipse(in: drawRect)

            if index > 0 {
                let prev = visiblePoints[index - 1]
                let dt = point.timestamp.timeIntervalSince(prev.timestamp)
                let prevMapPoint = MKMapPoint(prev.coordinate)
                let meters = mapPoint.distance(to: prevMapPoint)
                if dt <= 240 && meters <= 350 {
                    let p1 = self.point(for: prevMapPoint)
                    let p2 = self.point(for: mapPoint)
                    context.setLineWidth(drawRect.width)
                    context.move(to: p1)
                    context.addLine(to: p2)
                    context.strokePath()
                }
            }
        }

        context.restoreGState()
    }
}

struct FogMapView: UIViewRepresentable {
    let points: [TrackPoint]
    let userLocation: CLLocation?
    let centerOnUserTrigger: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = false

        // 位置情報未取得時でも日本（東京駅周辺）が初期表示されるように設定
        let defaultCenter = userLocation?.coordinate ?? CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671)
        let initialRegion = MKCoordinateRegion(
            center: defaultCenter,
            latitudinalMeters: 1500,
            longitudinalMeters: 1500
        )
        mapView.setRegion(initialRegion, animated: false)

        let osm = OSMTileOverlay()
        mapView.addOverlay(osm, level: .aboveLabels)

        let fog = FogOverlay(points: points)
        context.coordinator.fogOverlay = fog
        mapView.addOverlay(fog, level: .aboveLabels)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if !context.coordinator.hasCenteredOnUser, let loc = userLocation {
            context.coordinator.hasCenteredOnUser = true
            center(mapView, on: loc, animated: true)
        }

        if context.coordinator.lastCenterTrigger != centerOnUserTrigger, let loc = userLocation {
            context.coordinator.lastCenterTrigger = centerOnUserTrigger
            context.coordinator.hasCenteredOnUser = true
            center(mapView, on: loc, animated: true)
        }

        if context.coordinator.lastPointsCount != points.count || context.coordinator.lastPointID != points.last?.id {
            context.coordinator.lastPointsCount = points.count
            context.coordinator.lastPointID = points.last?.id
            context.coordinator.fogOverlay?.points = points
            if let fog = context.coordinator.fogOverlay,
               let renderer = mapView.renderer(for: fog) as? FogOverlayRenderer {
                renderer.setNeedsDisplay()
            }
        }
    }

    private func center(_ mapView: MKMapView, on location: CLLocation, animated: Bool) {
        let region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 1200,
            longitudinalMeters: 1200
        )
        mapView.setRegion(region, animated: animated)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var fogOverlay: FogOverlay?
        var hasCenteredOnUser = false
        var lastCenterTrigger = 0
        var lastPointsCount = -1
        var lastPointID: UUID?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            if let fog = overlay as? FogOverlay {
                return FogOverlayRenderer(overlay: fog)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
