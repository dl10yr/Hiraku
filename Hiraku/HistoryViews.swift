import SwiftUI
import MapKit

/// 計測履歴一覧画面
struct HistoryListView: View {
    let points: [TrackPoint]

    private var sessions: [TrackSession] {
        TrackSession.buildSessions(from: points)
    }

    var body: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "計測履歴がありません",
                    systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                    description: Text("移動してGPSログが記録されると、ここに履歴が表示されます。")
                )
            } else {
                List(sessions) { session in
                    NavigationLink {
                        HistoryDetailView(session: session)
                    } label: {
                        HistoryRowView(session: session)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("計測履歴")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HistoryRowView: View {
    let session: TrackSession

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: session.primaryMode.systemImage)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(dateRangeText)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 10) {
                    Label(distanceText, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    Label(durationText, systemImage: "clock")
                    Text("\(session.points.count)地点")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var dateRangeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        let start = formatter.string(from: session.startDate)
        let endFormatter = DateFormatter()
        endFormatter.locale = Locale(identifier: "ja_JP")
        endFormatter.dateFormat = "HH:mm"
        let end = endFormatter.string(from: session.endDate)
        return "\(start) 〜 \(end)"
    }

    private var distanceText: String {
        let meters = session.totalDistance
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        }
        return String(format: "%.0f m", meters)
    }

    private var durationText: String {
        let minutes = Int(session.duration) / 60
        let seconds = Int(session.duration) % 60
        if minutes >= 60 {
            return String(format: "%d時間%d分", minutes / 60, minutes % 60)
        } else if minutes > 0 {
            return "\(minutes)分\(seconds)秒"
        } else {
            return "\(seconds)秒"
        }
    }
}

/// 計測詳細画面（開始〜終了までのルート全体が画面に収まるように線で描画）
struct HistoryDetailView: View {
    let session: TrackSession

    var body: some View {
        VStack(spacing: 0) {
            SessionRouteMapView(points: session.points)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    summaryCard
                }
        }
        .navigationTitle("計測詳細")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryCard: some View {
        HStack(spacing: 20) {
            statItem(title: "移動距離", value: formattedDistance)
            Divider().frame(height: 32)
            statItem(title: "所要時間", value: formattedDuration)
            Divider().frame(height: 32)
            statItem(title: "主な手段", value: session.primaryMode.label)
            Divider().frame(height: 32)
            statItem(title: "記録数", value: "\(session.points.count)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(16)
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
    }

    private var formattedDistance: String {
        let meters = session.totalDistance
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        }
        return String(format: "%.0f m", meters)
    }

    private var formattedDuration: String {
        let minutes = Int(session.duration) / 60
        let seconds = Int(session.duration) % 60
        if minutes >= 60 {
            return String(format: "%dh %dm", minutes / 60, minutes % 60)
        } else if minutes > 0 {
            return "\(minutes)分\(seconds)秒"
        } else {
            return "\(seconds)秒"
        }
    }
}

/// 開始から終了までが1画面に収まるように自動ズームし、ルートを線で描画するマップ
struct SessionRouteMapView: View {
    let points: [TrackPoint]
    @State private var region: MKCoordinateRegion

    init(points: [TrackPoint]) {
        self.points = points
        _region = State(initialValue: Self.fittingRegion(for: points))
    }

    var body: some View {
        ZStack {
            RouteOSMMapRepresentable(
                points: points,
                initialRegion: Self.fittingRegion(for: points),
                region: $region
            )
            RouteLineCanvas(points: points, region: region)
        }
    }

    static func fittingRegion(for points: [TrackPoint]) -> MKCoordinateRegion {
        guard let first = points.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671),
                latitudinalMeters: 1000,
                longitudinalMeters: 1000
            )
        }

        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude

        for pt in points {
            minLat = min(minLat, pt.latitude)
            maxLat = max(maxLat, pt.latitude)
            minLon = min(minLon, pt.longitude)
            maxLon = max(maxLon, pt.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        // 開始から終了まで余白を持って画面内に収まるようにSpanを計算（最低約400m四方）
        let latSpan = max((maxLat - minLat) * 1.45, 0.004)
        let lonSpan = max((maxLon - minLon) * 1.45, 0.004)

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
        )
    }
}

private struct RouteOSMMapRepresentable: UIViewRepresentable {
    let points: [TrackPoint]
    let initialRegion: MKCoordinateRegion
    @Binding var region: MKCoordinateRegion

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false
        mapView.showsCompass = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false

        let osm = OSMTileOverlay()
        mapView.addOverlay(osm, level: .aboveLabels)

        DispatchQueue.main.async {
            mapView.setRegion(initialRegion, animated: false)
            context.coordinator.hasAppliedInitialRegion = true
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if !context.coordinator.hasAppliedInitialRegion, mapView.bounds.width > 0 {
            context.coordinator.hasAppliedInitialRegion = true
            mapView.setRegion(initialRegion, animated: false)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RouteOSMMapRepresentable
        var hasAppliedInitialRegion = false

        init(_ parent: RouteOSMMapRepresentable) {
            self.parent = parent
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            guard hasAppliedInitialRegion, mapView.bounds.width > 0 else { return }
            let r = mapView.region
            Task { @MainActor in
                self.parent.region = r
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard hasAppliedInitialRegion, mapView.bounds.width > 0 else { return }
            let r = mapView.region
            Task { @MainActor in
                self.parent.region = r
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

/// 開始〜終了の軌跡を線とマーカーで描画する Canvas
private struct RouteLineCanvas: View {
    let points: [TrackPoint]
    let region: MKCoordinateRegion

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0, !points.isEmpty else { return }

            let screenPoints = points.map { convertToScreen(coordinate: $0.coordinate, in: size, region: region) }

            // ルート線を描画
            if screenPoints.count >= 2 {
                var path = Path()
                path.move(to: screenPoints[0])
                for pt in screenPoints.dropFirst() {
                    path.addLine(to: pt)
                }

                // 白い縁取り
                context.stroke(
                    path,
                    with: .color(.white.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
                )
                // メインのルート線（ブルー）
                context.stroke(
                    path,
                    with: .color(.blue),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                )
            }

            // 開始地点マーカー（緑）
            if let startPt = screenPoints.first {
                drawMarker(in: &context, at: startPt, color: .green)
            }

            // 終了地点マーカー（赤）
            if let endPt = screenPoints.last, screenPoints.count > 1 {
                drawMarker(in: &context, at: endPt, color: .red)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawMarker(in context: inout GraphicsContext, at point: CGPoint, color: Color) {
        let outerRect = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
        let innerRect = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: outerRect), with: .color(.white))
        context.fill(Path(ellipseIn: innerRect), with: .color(color))
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

/// 設定画面（一旦空のシンプル構成）
struct SettingsView: View {
    var body: some View {
        List {
            // 今後の設定項目用（一旦空）
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
    }
}
