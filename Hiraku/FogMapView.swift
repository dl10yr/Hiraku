import SwiftUI
import MapKit

/// Apple 標準の MKMapView を使い、記録された徒歩・自転車のログを Line（MKPolyline）として高速描画するメインマップ
/// SwiftUI の Map + MapCameraPosition(.userLocation(fallback: .automatic)) は位置情報未確定かつポリラインが空の起動直後に
/// 白画面で待機・再計算を繰り返すことがあるため、UIKit の MKMapView を直接ラップして起動0秒で確実に地図を表示します。
struct FogMapView: UIViewRepresentable {
    let points: [TrackPoint]
    let userLocation: CLLocation?
    let centerOnUserTrigger: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.isPitchEnabled = false

        // 起動直後に真っ白にならないよう、即座に初期リージョン（現在地があれば現在地、なければ日本全体〜東京）をセット
        if let loc = userLocation {
            context.coordinator.hasCenteredOnUser = true
            context.coordinator.lastCenteredLocation = loc
            let region = MKCoordinateRegion(
                center: loc.coordinate,
                latitudinalMeters: 800,
                longitudinalMeters: 800
            )
            mapView.setRegion(region, animated: false)
        } else {
            let defaultRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671),
                latitudinalMeters: 5000,
                longitudinalMeters: 5000
            )
            mapView.setRegion(defaultRegion, animated: false)
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // 1. 初回測位時または 2km 以上ジャンプした時に自動で現在地へ移動
        if let loc = userLocation {
            let jumpedFar: Bool = {
                guard let lastCentered = context.coordinator.lastCenteredLocation else { return true }
                return loc.distance(from: lastCentered) > 2_000
            }()

            if !context.coordinator.hasCenteredOnUser || jumpedFar {
                context.coordinator.hasCenteredOnUser = true
                context.coordinator.lastCenteredLocation = loc
                center(mapView, on: loc, animated: true)
            }
        }

        // 2. 右上の現在地ボタンが押された時
        if context.coordinator.lastCenterTrigger != centerOnUserTrigger {
            context.coordinator.lastCenterTrigger = centerOnUserTrigger
            if let loc = userLocation ?? mapView.userLocation.location {
                context.coordinator.hasCenteredOnUser = true
                context.coordinator.lastCenteredLocation = loc
                center(mapView, on: loc, animated: true)
            }
        }

        // 3. ポイント配列が変化した時だけ MKPolyline を差分更新（毎フレーム再生成による重さを防止）
        let firstID = points.first?.id
        let lastID = points.last?.id
        if context.coordinator.renderedCount != points.count ||
           context.coordinator.renderedFirstID != firstID ||
           context.coordinator.renderedLastID != lastID {
            context.coordinator.renderedCount = points.count
            context.coordinator.renderedFirstID = firstID
            context.coordinator.renderedLastID = lastID

            mapView.removeOverlays(mapView.overlays)
            let segments = RouteSegment.buildSegments(from: points)
            let polylines: [ModePolyline] = segments.map { seg in
                let poly = ModePolyline(coordinates: seg.coordinates, count: seg.coordinates.count)
                poly.mode = seg.mode
                return poly
            }
            mapView.addOverlays(polylines, level: .aboveRoads)
        }
    }

    private func center(_ mapView: MKMapView, on location: CLLocation, animated: Bool) {
        let region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 800,
            longitudinalMeters: 800
        )
        mapView.setRegion(region, animated: animated)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var hasCenteredOnUser = false
        var lastCenteredLocation: CLLocation?
        var lastCenterTrigger = 0
        var renderedCount = -1
        var renderedFirstID: UUID?
        var renderedLastID: UUID?

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !hasCenteredOnUser, let loc = userLocation.location else { return }
            hasCenteredOnUser = true
            lastCenteredLocation = loc
            let region = MKCoordinateRegion(
                center: loc.coordinate,
                latitudinalMeters: 800,
                longitudinalMeters: 800
            )
            mapView.setRegion(region, animated: true)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? ModePolyline {
                let renderer = MKPolylineRenderer(polyline: poly)
                renderer.strokeColor = poly.mode == .walk ? UIColor.systemBlue : UIColor.systemOrange
                renderer.lineWidth = 5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

final class ModePolyline: MKPolyline {
    var mode: TransportMode = .walk
}
