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
                    description: Text("徒歩または自転車で移動すると、ここに履歴が表示されます。")
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
                .background(session.primaryMode == .walk ? Color.blue : Color.orange, in: Circle())

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

/// 計測詳細画面（Apple MapKit 上で開始〜終了までが1画面に収まるように線で描画）
struct HistoryDetailView: View {
    let session: TrackSession

    var body: some View {
        SessionDetailMapView(session: session)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                summaryCard
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
            statItem(title: "移動手段", value: session.primaryMode.label)
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

private struct SessionDetailMapView: UIViewRepresentable {
    let session: TrackSession

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false
        mapView.isPitchEnabled = false

        let coords = session.points.map(\.coordinate)
        if coords.count >= 2 {
            let poly = ModePolyline(coordinates: coords, count: coords.count)
            poly.mode = session.primaryMode
            mapView.addOverlay(poly, level: .aboveRoads)
        }

        if let first = coords.first {
            let startPin = MKPointAnnotation()
            startPin.coordinate = first
            startPin.title = "開始"
            mapView.addAnnotation(startPin)
        }

        if let last = coords.last, coords.count > 1 {
            let endPin = MKPointAnnotation()
            endPin.coordinate = last
            endPin.title = "終了"
            mapView.addAnnotation(endPin)
        }

        let region = Self.fittingRegion(for: session.points)
        mapView.setRegion(region, animated: false)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {}

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

        let latSpan = max((maxLat - minLat) * 1.5, 0.004)
        let lonSpan = max((maxLon - minLon) * 1.5, 0.004)

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
        )
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? ModePolyline {
                let renderer = MKPolylineRenderer(polyline: poly)
                renderer.strokeColor = poly.mode == .walk ? UIColor.systemBlue : UIColor.systemOrange
                renderer.lineWidth = 6
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
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
