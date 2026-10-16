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
        // Apple Maps の標準ベクター描画（VectorKit）を置換して、OpenStreetMap のみ表示＆VectorKitのアサーションを防止
        self.canReplaceMapContent = true
        self.minimumZ = 0
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

/// 訪れた場所だけ雲（霧）をくり抜いて描画する Canvas オーバーレイ View
/// MKMapView のカスタム MKOverlayRenderer ではなく SwiftUI Canvas で重畳することで、
/// iOS 27 シミュレータの VectorKit アサーションクラッシュ（EaselUtilities.cpp:376）を完全に回避し、
/// 60fps で滑らかなソフトエッジの雲を描画します。
struct FogCanvasOverlay: View {
    let points: [TrackPoint]
    let region: MKCoordinateRegion

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }

            // Canvas 内部を独立レイヤーにして destinationOut（くり抜き合成）を機能させる
            context.drawLayer { layer in
                // 1. 画面全体を「雲（白い霧〜スモーク）」で覆う
                let fullRect = CGRect(origin: .zero, size: size)
                layer.fill(
                    Path(fullRect),
                    with: .color(Color(red: 0.14, green: 0.17, blue: 0.22).opacity(0.76))
                )

                guard !points.isEmpty,
                      region.span.latitudeDelta > 0,
                      region.span.longitudeDelta > 0 else { return }

                // 1メートルあたりの画面ピクセル数を算出
                let metersPerDegreeLat = 111_132.0
                let visibleMetersLat = region.span.latitudeDelta * metersPerDegreeLat
                let pixelsPerMeter = size.height / max(visibleMetersLat, 1)

                // 表示範囲＋マージン内のポイントだけ抽出
                let latMargin = region.span.latitudeDelta * 0.6
                let lonMargin = region.span.longitudeDelta * 0.6
                let minLat = region.center.latitude - region.span.latitudeDelta / 2 - latMargin
                let maxLat = region.center.latitude + region.span.latitudeDelta / 2 + latMargin
                let minLon = region.center.longitude - region.span.longitudeDelta / 2 - lonMargin
                let maxLon = region.center.longitude + region.span.longitudeDelta / 2 + lonMargin

                let visiblePoints = points.filter { pt in
                    pt.latitude >= minLat && pt.latitude <= maxLat &&
                    pt.longitude >= minLon && pt.longitude <= maxLon
                }

                guard !visiblePoints.isEmpty else { return }

                layer.blendMode = .destinationOut

                // 2. 訪れた地点と連続する軌跡の雲をソフトエッジでくり抜く
                for (index, pt) in visiblePoints.enumerated() {
                    let screenPt = convertToScreen(
                        coordinate: pt.coordinate,
                        in: size,
                        region: region
                    )
                    // ズームアウトしすぎた時でも最低 14pt は見えるようにする
                    let radiusPx = max(14.0, CGFloat(pt.revealRadius) * pixelsPerMeter)

                    // 外側のふんわりした境界（ソフトエッジ）
                    let outerRadius = radiusPx * 1.45
                    let outerRect = CGRect(
                        x: screenPt.x - outerRadius,
                        y: screenPt.y - outerRadius,
                        width: outerRadius * 2,
                        height: outerRadius * 2
                    )
                    layer.fill(
                        Path(ellipseIn: outerRect),
                        with: .radialGradient(
                            Gradient(stops: [
                                .init(color: .white, location: 0.0),
                                .init(color: .white.opacity(0.85), location: 0.55),
                                .init(color: .clear, location: 1.0)
                            ]),
                            center: screenPt,
                            startRadius: 0,
                            endRadius: outerRadius
                        )
                    )

                    // 連続するポイント間を太いラインで繋ぐ
                    if index > 0 {
                        let prev = visiblePoints[index - 1]
                        let dt = pt.timestamp.timeIntervalSince(prev.timestamp)
                        let dist = CLLocation(latitude: pt.latitude, longitude: pt.longitude)
                            .distance(from: CLLocation(latitude: prev.latitude, longitude: prev.longitude))
                        if dt <= 240 && dist <= 400 {
                            let prevScreenPt = convertToScreen(
                                coordinate: prev.coordinate,
                                in: size,
                                region: region
                            )
                            var linePath = Path()
                            linePath.move(to: prevScreenPt)
                            linePath.addLine(to: screenPt)

                            layer.stroke(
                                linePath,
                                with: .color(.white.opacity(0.45)),
                                style: StrokeStyle(lineWidth: radiusPx * 2.5, lineCap: .round, lineJoin: .round)
                            )
                            layer.stroke(
                                linePath,
                                with: .color(.white),
                                style: StrokeStyle(lineWidth: radiusPx * 1.8, lineCap: .round, lineJoin: .round)
                            )
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func convertToScreen(
        coordinate: CLLocationCoordinate2D,
        in size: CGSize,
        region: MKCoordinateRegion
    ) -> CGPoint {
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2

        let xRatio = (coordinate.longitude - minLon) / max(maxLon - minLon, 0.000001)
        let yRatio = (maxLat - coordinate.latitude) / max(maxLat - minLat, 0.000001)

        return CGPoint(
            x: CGFloat(xRatio) * size.width,
            y: CGFloat(yRatio) * size.height
        )
    }
}

/// OpenStreetMap タイルを表示し、カメラ移動をリアルタイムに通知する MKMapView ラッパー
struct OSMMapView: UIViewRepresentable {
    let userLocation: CLLocation?
    let centerOnUserTrigger: Int
    @Binding var region: MKCoordinateRegion

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false

        let osm = OSMTileOverlay()
        mapView.addOverlay(osm, level: .aboveLabels)

        if let loc = userLocation {
            context.coordinator.hasCenteredOnUser = true
            center(mapView, on: loc, animated: false)
        }

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
    }

    private func center(_ mapView: MKMapView, on location: CLLocation, animated: Bool) {
        let newRegion = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 1000,
            longitudinalMeters: 1000
        )
        mapView.setRegion(newRegion, animated: animated)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: OSMMapView
        var hasCenteredOnUser = false
        var lastCenterTrigger = 0

        init(_ parent: OSMMapView) {
            self.parent = parent
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            let currentRegion = mapView.region
            Task { @MainActor in
                self.parent.region = currentRegion
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let currentRegion = mapView.region
            Task { @MainActor in
                self.parent.region = currentRegion
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

struct FogMapView: View {
    let points: [TrackPoint]
    let userLocation: CLLocation?
    let centerOnUserTrigger: Int

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3346, longitude: -122.0090),
        latitudinalMeters: 2000,
        longitudinalMeters: 2000
    )

    var body: some View {
        ZStack {
            OSMMapView(
                userLocation: userLocation,
                centerOnUserTrigger: centerOnUserTrigger,
                region: $region
            )
            FogCanvasOverlay(
                points: points,
                region: region
            )
        }
    }
}
