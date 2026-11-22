import MapKit
import SwiftData
import SwiftUI
import iWalkCore
import iWalkStore

/// Full-screen live view for either a phone-recorded walk or a mirrored Watch workout.
struct LiveWorkoutView: View {
    @Environment(TrackingSession.self) private var tracking
    @Environment(MirroredWorkout.self) private var mirror
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        if mirror.isActive {
            MirroredView()
        } else {
            PhoneTrackingView()
        }
    }
}

private struct PhoneTrackingView: View {
    @Environment(TrackingSession.self) private var tracking
    @Environment(NetworkMonitor.self) private var network
    @State private var plainBackground = false
    @State private var confirmingStop = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if plainBackground || !network.isOnline {
                    RouteShapeView(planned: tracking.route?.coords ?? [],
                                   track: tracking.track.points.map(\.coordinate),
                                   current: tracking.currentLocation)
                        .background(Color(.secondarySystemBackground))
                } else {
                    Map(initialPosition: .userLocation(followsHeading: false, fallback: .automatic)) {
                        UserAnnotation()
                        if let route = tracking.route {
                            MapPolyline(coordinates: route.coords.map(\.clCoordinate))
                                .stroke(.gray.opacity(0.7), lineWidth: 6)
                        }
                        MapPolyline(coordinates: tracking.track.points.map(\.coordinate.clCoordinate))
                            .stroke(.orange, lineWidth: 5)
                    }
                }
                if tracking.isOffRoute {
                    Banner(text: "Off route. More than 30 m from the planned path.",
                           systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(plainBackground ? "Map" : "Plain", systemImage: plainBackground ? "map" : "scribble") {
                    plainBackground.toggle()
                }
                .buttonStyle(.bordered)
                .padding()
            }

            VStack(spacing: 16) {
                Text(tracking.route?.name ?? tracking.activity.title).font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Format.duration(ctx.date.timeIntervalSince(tracking.startedAt ?? ctx.date)))
                        .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                }
                HStack {
                    Stat(title: "Distance", value: Format.distance(km: tracking.distanceKm))
                    Stat(title: "Pace", value: Format.pace(secondsPerKm: tracking.currentPaceSecPerKm ?? tracking.averagePaceSecPerKm))
                    Stat(title: "Remaining", value: tracking.remainingKm.map { Format.distance(km: $0) } ?? "—")
                    if let heartRate = tracking.heartRate {
                        Stat(title: "Heart rate", value: "\(Int(heartRate)) bpm")
                    }
                }
                if let acc = tracking.lastAccuracyM {
                    Text("GPS ±\(Int(acc)) m").font(.caption).foregroundStyle(acc > 30 ? .red : .secondary)
                }
                if let error = tracking.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button(role: .destructive) {
                    confirmingStop = true
                } label: {
                    Label(tracking.state == .saving ? "Saving…" : "Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(tracking.state != .running)
            }
            .padding()
        }
        .confirmationDialog("Finish this workout?", isPresented: $confirmingStop) {
            Button("Save") { Task { await tracking.stop() } }
            Button("Discard", role: .destructive) { tracking.discard() }
            Button("Keep going", role: .cancel) {}
        }
    }
}

private struct MirroredView: View {
    @Environment(MirroredWorkout.self) private var mirror
    @Query private var routes: [RouteRecord]

    private var current: Coordinate? {
        guard let lat = mirror.latest?.latitude, let lon = mirror.latest?.longitude else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }

    var body: some View {
        VStack(spacing: 16) {
            Label(mirror.isConnected ? "Recording on Apple Watch" : "Watch out of range. Still recording on the Watch.",
                  systemImage: "applewatch")
                .font(.subheadline)
                .foregroundStyle(mirror.isConnected ? Color.secondary : Color.orange)
            Text(mirror.latest?.routeName ?? mirror.activity.title).font(.title2.bold())
            if mirror.latest?.offRoute == true {
                Banner(text: "Off route", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Format.duration(mirror.elapsed))
                    .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
            }
            Grid(horizontalSpacing: 12, verticalSpacing: 16) {
                GridRow {
                    Stat(title: "Distance", value: Format.distance(km: mirror.distanceKm))
                    Stat(title: "Pace", value: Format.pace(secondsPerKm: mirror.paceSecPerKm))
                }
                GridRow {
                    Stat(title: "Heart rate", value: mirror.heartRate.map { "\(Int($0)) bpm" } ?? "—")
                    Stat(title: "Remaining", value: mirror.latest?.remainingKm.map { Format.distance(km: $0) } ?? "—")
                }
            }
            if let routeId = mirror.latest?.routeId, let route = routes.first(where: { $0.id == routeId }) {
                RouteShapeView(planned: route.coords, current: current)
                    .frame(height: 220)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            Spacer()
            Text(mirror.isPaused ? "Paused on Watch" : "Pause or end the workout on your Watch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
