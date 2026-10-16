import SwiftUI
import MapKit

/// OpenStreetMap タイルオーバーレイ（User-Agent ヘッダ付与）
final class OSMTileOverlay: MKTileOverlay {
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "Hiraku/1.0 (iOS OSM FogMap)"]
        return URLSession(configuration: config)
    }()

    init() {
        super.init(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        self.canReplaceMapContent = true
        self.maximumZ = 19
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let url = self.url(forTilePath: path)
        session.dataTask(with: url) { data, _, error in
            result(data, error)
        }.resume()
    }
}

private struct SpatialPointIndex {
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

        var result: [TrackPoint] = []
        result.reserveCapacity((maxLatBucket - minLatBucket + 1) * (maxLonBucket - minLonBucket + 1) * 4)

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
final class FogOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world

    var points: [TrackPoint] {
        didSet {
            pointIndex.rebuild(with: points)
        }
    }

    private var pointIndex: SpatialPointIndex

    init(points: [TrackPoint]) {
        self.points = points
        self.pointIndex = SpatialPointIndex(points: points)
    }

    func visiblePoints(in mapRect: MKMapRect, paddingMeters: CLLocationDistance) -> [TrackPoint] {
        pointIndex.points(in: mapRect, paddingMeters: paddingMeters)
    }
}

/// 訪れた場所だけ雲をくり抜くレンダラー
final class FogOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let fogOverlay = overlay as? FogOverlay else { return }

        let rect = self.rect(for: mapRect)
        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        context.setFillColor(UIColor(white: 0.08, alpha: 0.82).cgColor)
        context.fill(rect)

        let visiblePoints = fogOverlay.visiblePoints(in: mapRect, paddingMeters: 420)
        guard !visiblePoints.isEmpty else {
            context.restoreGState()
            return
        }

        let baseWidth = max(24, 88 / zoomScale)
        let path = revealPath(for: visiblePoints, in: mapRect, minimumScreenSpacing: max(6, baseWidth * 0.18))

        context.setBlendMode(.destinationOut)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.addPath(path)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.34).cgColor)
        context.setLineWidth(baseWidth * 1.7)
        context.strokePath()

        context.addPath(path)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(baseWidth)
        context.strokePath()

        context.restoreGState()
    }

    private func revealPath(
        for points: [TrackPoint],
        in mapRect: MKMapRect,
        minimumScreenSpacing: CGFloat
    ) -> CGPath {
        let expandedRect = mapRect.insetBy(dx: -mapRect.size.width * 0.2, dy: -mapRect.size.height * 0.2)
        let path = CGMutablePath()

        var previousAccepted: CGPoint?
        var lastAcceptedTimestamp: Date?

        for point in points {
            let mapPoint = MKMapPoint(point.coordinate)
            guard expandedRect.contains(mapPoint) else { continue }

            let screenPoint = self.point(for: mapPoint)

            if let previousAccepted, let lastAcceptedTimestamp {
                let segmentDistance = hypot(screenPoint.x - previousAccepted.x, screenPoint.y - previousAccepted.y)
                let timeGap = point.timestamp.timeIntervalSince(lastAcceptedTimestamp)

                if timeGap > 240 || segmentDistance > 220 {
                    path.move(to: screenPoint)
                    path.addLine(to: screenPoint)
                } else if segmentDistance >= minimumScreenSpacing || point.isInterpolated {
                    path.move(to: previousAccepted)
                    path.addLine(to: screenPoint)
                }
            } else {
                path.move(to: screenPoint)
                path.addLine(to: screenPoint)
            }

            previousAccepted = screenPoint
            lastAcceptedTimestamp = point.timestamp
        }

        return path
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
            center(mapView, on: loc, animated: false)
        }

        if context.coordinator.lastCenterTrigger != centerOnUserTrigger, let loc = userLocation {
            context.coordinator.lastCenterTrigger = centerOnUserTrigger
            context.coordinator.hasCenteredOnUser = true
            center(mapView, on: loc, animated: true)
        }

        context.coordinator.fogOverlay?.points = points
        if let fog = context.coordinator.fogOverlay,
           let renderer = mapView.renderer(for: fog) as? FogOverlayRenderer {
            renderer.setNeedsDisplay()
        }
    }

    private func center(_ mapView: MKMapView, on location: CLLocation, animated: Bool) {
        let region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 1500,
            longitudinalMeters: 1500
        )
        mapView.setRegion(region, animated: animated)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var fogOverlay: FogOverlay?
        var hasCenteredOnUser = false
        var lastCenterTrigger = 0

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
