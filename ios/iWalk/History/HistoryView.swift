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
                                       badge: s.source == .watch ? "applewatch" : "iphone",
                                       note: s.routeReview == .pending ? "Different path from the route. Review" : nil)
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
    var note: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text("\(date.formatted(date: .abbreviated, time: .shortened)) · \(Format.distance(km: distanceKm)) · \(Format.duration(duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let note {
                    Label(note, systemImage: "arrow.triangle.branch")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
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
    @Environment(AppServices.self) private var services
    @Environment(RouteReviewer.self) private var reviewer
    @Environment(\.modelContext) private var context
    @Query private var routes: [RouteRecord]

    /// Heart rate and energy often reach Health after the walk ends (a Watch syncing its readings,
    /// the iPhone's own energy estimate), so fill the gaps whenever the session is opened.
    private func fillVitalsFromHealth() async {
        guard session.avgHR == nil || session.activeEnergyKcal == nil else { return }
        let vitals = await HealthVitals.read(from: services.health, start: session.start, end: session.end)
        guard vitals.avgHR != nil || vitals.activeEnergyKcal != nil else { return }
        session.avgHR = session.avgHR ?? vitals.avgHR
        session.activeEnergyKcal = session.activeEnergyKcal ?? vitals.activeEnergyKcal
        try? context.save()
    }

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
                    Stat(title: "Calories", value: session.activeEnergyKcal.map { "\(Int($0.rounded()))" } ?? "—")
                }
            }
            RouteReviewSection(session: session, original: planned, track: track)
            if session.routeId == nil, let valhalla = AppConfig.makeValhalla() {
                Section {
                    Button(snapping ? "Snapping…" : "Snap track to paths", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                        snapping = true
                        Task {
                            do {
                                snapped = try await valhalla.snap(track: track, activity: session.activity).coords
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
        .task { await fillVitalsFromHealth() }
    }
}

/// Shown on a walk that followed a saved route: whether it matched, and when it didn't,
/// the walked path (snapped to OSM paths) with a choice to update the route.
private struct RouteReviewSection: View {
    let session: SessionRecord
    let original: [Coordinate]
    let track: [Coordinate]
    @Environment(RouteReviewer.self) private var reviewer
    @Environment(NetworkMonitor.self) private var network
    @State private var confirmingUpdate = false

    var body: some View {
        if session.routeId == nil, session.routeReview == nil, Geo.length(of: track) >= RouteReviewer.minimumNewRouteM {
            Section {
                Label(network.isOnline ? "Saving this walk as a route…" : "This walk will be saved as a route, matched to the map, when you're online.",
                      systemImage: "map")
                    .font(.subheadline)
                if let error = reviewer.lastError { Text(error).font(.caption).foregroundStyle(.red) }
            }
        } else if session.routeId != nil {
            switch session.routeReview {
            case .created:
                Section { Label("Saved as a route: “\(session.routeName ?? "")”", systemImage: "checkmark.circle").foregroundStyle(.green) }
            case .pending:
                if let proposal = session.routeProposal { pendingSection(proposal) }
            case .applied:
                Section { Label("Route updated from this walk", systemImage: "checkmark.circle").foregroundStyle(.green) }
            case .matched:
                Section { Label("You followed the saved route", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            case .dismissed:
                EmptyView()
            case nil:
                if !original.isEmpty,
                   RouteComparison.compare(track: track, planned: RouteGeometry(original)).differs {
                    Section {
                        Label(network.isOnline ? "Checking the path you walked…" : "You took a different path. iWalk will match it to the map and offer to update the route when you're online.",
                              systemImage: "arrow.triangle.branch")
                            .font(.subheadline)
                        if let error = reviewer.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
        }
    }

    private func pendingSection(_ proposal: RouteDTO) -> some View {
        Section {
            RouteShapeView(planned: original, track: proposal.coords)
                .frame(height: 220)
                .listRowInsets(EdgeInsets())
            HStack {
                Stat(title: "Saved route", value: Format.distance(km: Geo.length(of: original) / 1000))
                Stat(title: "Walked path", value: Format.distance(km: proposal.distanceKm))
                Stat(title: "Climb", value: proposal.elevGainM.map { "\(Int($0.rounded())) m" } ?? "—")
            }
            Button("Update “\(proposal.name)”", systemImage: "arrow.triangle.2.circlepath") { confirmingUpdate = true }
            Button("Save as new route", systemImage: "plus.square.on.square") { reviewer.decide(.saveAsNewRoute, for: session) }
            Button("Keep original route", systemImage: "xmark", role: .cancel) { reviewer.decide(.keepOriginal, for: session) }
        } header: {
            Text("You took a different path")
        } footer: {
            Text("Grey is the saved route, orange is the path you walked, matched to OpenStreetMap paths. Updating replaces the saved route on your iPhone and Watch.")
        }
        .confirmationDialog("Replace “\(proposal.name)” with the path you walked?", isPresented: $confirmingUpdate, titleVisibility: .visible) {
            Button("Update route") { reviewer.decide(.updateRoute, for: session) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
