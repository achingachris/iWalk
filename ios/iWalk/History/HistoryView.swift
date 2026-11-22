import HealthKit
import SwiftData
import SwiftUI
import iWalkCore
import iWalkStore

/// iWalk sessions (phone and Watch) plus other Health workouts, without duplicates.
struct HistoryView: View {
    @Query(sort: \SessionRecord.start, order: .reverse) private var sessions: [SessionRecord]
    @Environment(AppServices.self) private var services
    @State private var healthWorkouts: [HKWorkout] = []

    private var otherWorkouts: [HKWorkout] {
        let known = Set(sessions.compactMap(\.healthKitUUID))
        return healthWorkouts.filter { !known.contains($0.uuid) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("iWalk") {
                    if sessions.isEmpty {
                        Text("No recorded sessions yet.").foregroundStyle(.secondary)
                    }
                    ForEach(sessions) { s in
                        NavigationLink {
                            SessionDetailView(session: s)
                        } label: {
                            SessionRow(icon: s.activity.systemImage, title: s.routeName ?? s.activity.title,
                                       date: s.start, distanceKm: s.distanceKm,
                                       duration: s.end.timeIntervalSince(s.start),
                                       badge: s.source == .watch ? "applewatch" : "iphone")
                        }
                    }
                }
                Section("Other Health workouts") {
                    ForEach(otherWorkouts, id: \.uuid) { w in
                        SessionRow(icon: ActivityKind(workoutActivityType: w.workoutActivityType).systemImage,
                                   title: w.workoutActivityType == .hiking ? "Hike" : w.workoutActivityType == .running ? "Run" : "Walk",
                                   date: w.startDate,
                                   distanceKm: (w.statistics(for: HKQuantityType(.distanceWalkingRunning))?
                                       .sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo))) ?? 0,
                                   duration: w.duration, badge: "heart")
                    }
                }
            }
            .navigationTitle("History")
            .refreshable { await loadWorkouts() }
            .task { await loadWorkouts() }
        }
    }

    private func loadWorkouts() async {
        let types: [HKWorkoutActivityType] = [.walking, .hiking, .running]
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: types.map { HKQuery.predicateForWorkouts(with: $0) })
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 50
        )
        do {
            healthWorkouts = try await descriptor.result(for: services.health)
        } catch {
            healthWorkouts = []
        }
    }
}

private struct SessionRow: View {
    let icon: String
    let title: String
    let date: Date
    let distanceKm: Double
    let duration: TimeInterval
    let badge: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text("\(date.formatted(date: .abbreviated, time: .shortened)) · \(Format.distance(km: distanceKm)) · \(Format.duration(duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: badge).foregroundStyle(.secondary)
        }
    }
}

private struct SessionDetailView: View {
    let session: SessionRecord
    @State private var snapped: [Coordinate]?
    @State private var snapping = false
    @State private var snapError: String?
    @Environment(NetworkMonitor.self) private var network
    @Query private var routes: [RouteRecord]

    var body: some View {
        let track = session.trackPoints.map(\.coordinate)
        let planned = routes.first { $0.id == session.routeId }?.coords ?? []
        List {
            Section {
                RouteShapeView(planned: snapped ?? planned, track: track)
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
                HStack {
                    Stat(title: "Distance", value: Format.distance(km: session.distanceKm))
                    Stat(title: "Time", value: Format.duration(session.end.timeIntervalSince(session.start)))
                    Stat(title: "Avg HR", value: session.avgHR.map { "\(Int($0))" } ?? "—")
                }
            }
            if let valhalla = AppConfig.makeValhalla() {
                Section {
                    Button(snapping ? "Snapping…" : "Snap track to paths", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                        snapping = true
                        Task {
                            do {
                                snapped = try await valhalla.snap(track: track, activity: session.activity)
                            } catch {
                                snapError = error.localizedDescription
                            }
                            snapping = false
                        }
                    }
                    .disabled(!network.isOnline || snapping || track.count < 2)
                } footer: {
                    Text(snapError ?? "Online only. Shows the recorded track matched to OpenStreetMap paths in grey.")
                }
            }
        }
        .navigationTitle(session.routeName ?? session.activity.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
