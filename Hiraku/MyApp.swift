import SwiftUI

@main
struct MyApp: App {
    @StateObject private var recorder = LocationRecorder()
    @State private var filter: RevealFilter = .all
    @State private var centerOnUserTrigger = 0

    private var filteredPoints: [TrackPoint] {
        switch filter {
        case .all:
            recorder.points
        case .walkOnly:
            recorder.points.filter { $0.mode.isWalking }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottom) {
                FogMapView(
                    points: filteredPoints,
                    userLocation: recorder.lastLocation,
                    centerOnUserTrigger: centerOnUserTrigger
                )
                .ignoresSafeArea()

                VStack {
                    HStack {
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
                        .disabled(recorder.lastLocation == nil)
                        .padding(.top, 12)
                        .padding(.trailing, 16)
                    }

                    Spacer()

                    controlBar
                }
                .ignoresSafeArea(edges: .top)
            }
            .onAppear {
                recorder.startOnLaunchIfNeeded()
            }
        }
    }

    private var controlBar: some View {
        VStack(spacing: 12) {
            Picker("表示フィルター", selection: $filter) {
                ForEach(RevealFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(recorder.isRecording ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(recorder.isRecording ? "計測中 (\(recorder.currentMode.label))" : "停止中")
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
