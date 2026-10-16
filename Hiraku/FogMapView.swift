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

/// 地図全体を覆う「雲（霧）」のオーバーレイ
final class FogOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    var points: [TrackPoint]

    init(points: [TrackPoint]) {
        self.points = points
    }
}

/// 訪れた場所だけ雲をくり抜くレンダラー
final class FogOverlayRenderer: MKOverlayRenderer {
    var points: [TrackPoint]

    init(overlay: FogOverlay, points: [TrackPoint]) {
        self.points = points
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let rect = self.rect(for: mapRect)
        context.saveGState()

        // 1. 雲（暗い霧）で塗る
        context.setFillColor(UIColor(white: 0.08, alpha: 0.82).cgColor)
        context.fill(rect)

        // 2. 訪れた座標の周辺をクリア（くり抜く）
        context.setBlendMode(.clear)
        for pt in points {
            let mapPoint = MKMapPoint(pt.coordinate)
            let radiusInMapPoints = pt.revealRadius * MKMapPointsPerMeterAtLatitude(pt.latitude)
            let pointRect = MKMapRect(
                x: mapPoint.x - radiusInMapPoints,
                y: mapPoint.y - radiusInMapPoints,
                width: radiusInMapPoints * 2,
                height: radiusInMapPoints * 2
            )
            guard mapRect.intersects(pointRect) else { continue }
            let drawRect = self.rect(for: pointRect)
            context.fillEllipse(in: drawRect)
        }

        context.restoreGState()
    }
}

struct FogMapView: UIViewRepresentable {
    let points: [TrackPoint]
    let userLocation: CLLocation?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = false

        // OpenStreetMap タイルを最背面に敷く
        let osm = OSMTileOverlay()
        mapView.addOverlay(osm, level: .aboveLabels)

        // 雲オーバーレイをその上に重ねる
        let fog = FogOverlay(points: points)
        context.coordinator.fogOverlay = fog
        mapView.addOverlay(fog, level: .aboveLabels)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if !context.coordinator.hasCenteredOnUser, let loc = userLocation {
            context.coordinator.hasCenteredOnUser = true
            let region = MKCoordinateRegion(
                center: loc.coordinate,
                latitudinalMeters: 1500,
                longitudinalMeters: 1500
            )
            mapView.setRegion(region, animated: true)
        }

        context.coordinator.fogOverlay?.points = points
        if let fog = context.coordinator.fogOverlay,
           let renderer = mapView.renderer(for: fog) as? FogOverlayRenderer {
            renderer.points = points
            renderer.setNeedsDisplay()
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var fogOverlay: FogOverlay?
        var hasCenteredOnUser = false

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            if let fog = overlay as? FogOverlay {
                return FogOverlayRenderer(overlay: fog, points: fog.points)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
