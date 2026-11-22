import SwiftData
import SwiftUI
import WatchConnectivity
import iWalkCore
import iWalkStore

struct HomeView: View {
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \RouteRecord.updatedAt, order: .reverse) private var routes: [RouteRecord]

    var body: some View {
        NavigationStack {
            List {
                Section("Routes") {
                    if routes.isEmpty {
                        Text("Plan and save a route on your iPhone. It syncs here, no internet needed.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(routes) { route in
                        Button {
                            let dto = route.dto
                            Task { await workout.start(activity: dto.activity, route: dto) }
                        } label: {
                            VStack(alignment: .leading) {
                                Label(route.name, systemImage: route.activity.systemImage)
                                Text(Format.distance(km: route.distanceKm))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Free workout") {
                    ForEach(ActivityKind.allCases) { kind in
                        Button(kind.title, systemImage: kind.systemImage) {
                            Task { await workout.start(activity: kind, route: nil) }
                        }
                    }
                }
                Section {
                    NavigationLink("Sync status") { WatchSyncView() }
                }
                if let error = workout.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("iWalk")
        }
        .fullScreenCover(isPresented: .constant(workout.phase != .idle)) {
            if workout.phase == .summary {
                SummaryView()
            } else {
                WorkoutView()
            }
        }
        .task {
            await workout.requestAuthorization()
            #if DEBUG
            // Screenshot helper: `-demoRoute "Old Town Heritage Walk"` starts that route's workout
            // (the Watch simulator can't be tapped from the command line). Debug builds only.
            if let name = UserDefaults.standard.string(forKey: "demoRoute"),
               let route = routes.first(where: { $0.name == name })?.dto {
                await workout.start(activity: route.activity, route: route)
            }
            #endif
        }
    }
}

struct WorkoutView: View {
    @Environment(WorkoutManager.self) private var workout
    // Debug screenshot helper: `-demoPage 2` opens a given page (0 controls, 1 stats, 2 route).
    @State private var page = UserDefaults.standard.object(forKey: "demoPage") == nil
        ? 1 : UserDefaults.standard.integer(forKey: "demoPage")

    var body: some View {
        TabView(selection: $page) {
            ControlsPage().tag(0)
            StatsPage().tag(1)
            RoutePage().tag(2)
        }
        .tabViewStyle(.page)
    }
}

private struct ControlsPage: View {
    @Environment(WorkoutManager.self) private var workout

    var body: some View {
        VStack(spacing: 12) {
            Button {
                workout.end()
            } label: {
                Label("End", systemImage: "xmark")
            }
            .tint(.red)
            .disabled(workout.phase == .ending)

            if workout.phase == .paused {
                Button("Resume", systemImage: "play.fill") { workout.resume() }.tint(.green)
            } else {
                Button("Pause", systemImage: "pause.fill") { workout.pause() }.tint(.yellow)
                    .disabled(workout.phase != .running)
            }
        }
        .padding()
    }
}

private struct StatsPage: View {
    @Environment(WorkoutManager.self) private var workout

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 4) {
                Text(Format.duration(workout.builder?.elapsedTime(at: ctx.date) ?? 0))
                    .font(.system(.title, design: .rounded).monospacedDigit())
                    .foregroundStyle(.yellow)
                Text(Format.distance(km: workout.distanceKm)).font(.title3.monospacedDigit())
                Text(workout.heartRate.map { "\(Int($0)) bpm" } ?? "-- bpm").font(.title3.monospacedDigit())
                if let remaining = workout.remainingKm {
                    Text("\(Format.distance(km: remaining)) left").font(.body.monospacedDigit())
                }
                if workout.isOffRoute {
                    Label("Off route", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote.bold())
                }
                if workout.phase == .paused {
                    Text("Paused").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        }
    }
}

private struct RoutePage: View {
    @Environment(WorkoutManager.self) private var workout

    var body: some View {
        RouteShapeView(planned: workout.route?.coords ?? [],
                       track: workout.track.points.map(\.coordinate),
                       current: workout.currentLocation,
                       lineWidth: 3)
            .overlay(alignment: .top) {
                if workout.isOffRoute {
                    Text("Off route").font(.caption.bold()).foregroundStyle(.red)
                }
            }
    }
}

private struct SummaryView: View {
    @Environment(WorkoutManager.self) private var workout

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Saved to Health").font(.headline)
                if let s = workout.lastSession {
                    Text(Format.duration(s.duration)).font(.title2.monospacedDigit())
                    Text(Format.distance(km: s.distanceKm))
                    if let hr = s.avgHR { Text("Avg \(Int(hr)) bpm") }
                    Text("Sends to iPhone when it's nearby.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let error = workout.lastError {
                    Text(error).foregroundStyle(.red)
                }
                Button("Done") { workout.dismissSummary() }
            }
            .padding()
        }
    }
}

struct WatchSyncView: View {
    @Environment(WatchSync.self) private var sync

    var body: some View {
        List {
            LabeledContent("Activation", value: sync.activationState == .activated ? "Activated" : "Not active")
            LabeledContent("Phone reachable", value: sync.isReachable ? "Yes" : "No")
            LabeledContent("Route version", value: "\(sync.appliedVersion)")
            LabeledContent("Outbox", value: "\(sync.outboxCount)")
            LabeledContent("Transfers", value: "\(sync.outstandingTransfers)")
            LabeledContent("Routes in", value: sync.lastRoutesAt?.formatted(date: .omitted, time: .shortened) ?? "—")
            LabeledContent("Session out", value: sync.lastSessionSentAt?.formatted(date: .omitted, time: .shortened) ?? "—")
            if let error = sync.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
            Button("Retry sending") { sync.flushOutbox() }
        }
        .navigationTitle("Sync")
        .onAppear { sync.refresh() }
    }
}
