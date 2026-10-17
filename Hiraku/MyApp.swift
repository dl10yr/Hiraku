import SwiftUI

@main
struct MyApp: App {
    @StateObject private var recorder = LocationRecorder()
    @State private var filter: RouteFilter = .all
    @State private var centerOnUserTrigger = 0

    private var filteredPoints: [TrackPoint] {
        switch filter {
        case .all:
            recorder.points
        case .walkOnly:
            recorder.points.filter { $0.mode == .walk }
        case .cycleOnly:
            recorder.points.filter { $0.mode == .cycle }
        }
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ZStack(alignment: .bottom) {
                    FogMapView(
                        points: filteredPoints,
                        userLocation: recorder.lastLocation,
                        centerOnUserTrigger: centerOnUserTrigger
                    )
                    .ignoresSafeArea()

                    VStack {
                        topBar

                        Spacer()

                        controlBar
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .onAppear {
                    recorder.startOnLaunchIfNeeded()
                }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            NavigationLink {
                HistoryListView(points: recorder.points)
            } label: {
                Image(systemName: "list.bullet")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }

            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            Button {
                centerOnUserTrigger += 1
            } label: {
                Image(systemName: "location.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 16)
    }

    private var statusText: String {
        guard recorder.isRecording else { return "停止中" }
        if let mode = recorder.detectedMode {
            return "記録中 (\(mode.label))"
        } else {
            return "待機中 (徒歩・自転車のみ記録)"
        }
    }

    private var controlBar: some View {
        VStack(spacing: 12) {
            Picker("表示フィルター", selection: $filter) {
                ForEach(RouteFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(recorder.isRecording ? (recorder.detectedMode != nil ? Color.green : Color.orange) : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("累計 \(filteredPoints.count) 地点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    recorder.toggleRecording()
                } label: {
                    Label(
                        recorder.isRecording ? "停止" : "再開",
                        systemImage: recorder.isRecording ? "stop.fill" : "play.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(recorder.isRecording ? Color.red : Color.accentColor, in: Capsule())
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}
