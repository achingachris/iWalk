import SwiftData
import SwiftUI
import iWalkCore
import iWalkStore

struct RoutesView: View {
    @Query(sort: \RouteRecord.updatedAt, order: .reverse) private var routes: [RouteRecord]
    @Environment(\.modelContext) private var context
    @Environment(PhoneSync.self) private var sync
    @Environment(AppServices.self) private var services
    @Environment(TrackingSession.self) private var tracking
    @Environment(MirroredWorkout.self) private var mirror
    @State private var startingOnWatch = false
    @State private var startMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let startMessage {
                    Text(startMessage).font(.footnote).foregroundStyle(.orange)
                }
                ForEach(routes) { route in
                    NavigationLink(value: route.id) {
                        RouteRow(route: route)
                    }
                }
                .onDelete(perform: delete)
            }
            .overlay {
                if routes.isEmpty {
                    ContentUnavailableView("No saved routes", systemImage: "map",
                                           description: Text("Plan a route while online, or tap Start for a walk without one. It's saved as a route when you finish."))
                }
            }
            .navigationTitle("Routes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    startMenu
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let route = routes.first(where: { $0.id == id }) {
                    RouteDetailView(route: route)
                }
            }
        }
    }

    /// Start a walk, hike or run without a planned route. When it ends (and the phone is online)
    /// it is saved as a new route.
    private var startMenu: some View {
        Menu {
            if sync.canStartOnWatch {
                Section("On Apple Watch") {
                    ForEach(ActivityKind.allCases) { kind in
                        Button(kind.title, systemImage: kind.systemImage) {
                            startMessage = nil
                            startingOnWatch = true
                            Task {
                                startMessage = await services.startOnWatch(activity: kind, route: nil)
                                startingOnWatch = false
                            }
                        }
                    }
                }
            }
            Section("On iPhone") {
                ForEach(ActivityKind.allCases) { kind in
                    Button(kind.title, systemImage: kind.systemImage) {
                        startMessage = nil
                        tracking.start(route: nil, activity: kind)
                    }
                }
            }
        } label: {
            if startingOnWatch {
                ProgressView()
            } else {
                Label("Start", systemImage: "play.fill")
            }
        }
        .disabled(tracking.state != .idle || mirror.isActive || startingOnWatch)
        .accessibilityLabel("Start a workout without a route")
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets { context.delete(routes[i]) }
        try? context.save()
        sync.routesChanged()
    }
}

private struct RouteRow: View {
    let route: RouteRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: route.activity.systemImage)
                .font(.title2)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.name).font(.headline)
                Text([Format.distance(km: route.distanceKm), Format.minutes(route.durationMin),
                      route.elevGainM.map { "↑ \(Int($0.rounded())) m" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct RouteDetailView: View {
    let route: RouteRecord
    @Environment(\.modelContext) private var context
    @Environment(PhoneSync.self) private var sync
    @Environment(AppServices.self) private var services
    @Environment(TrackingSession.self) private var tracking
    @Environment(MirroredWorkout.self) private var mirror

    @State private var renaming = false
    @State private var newName = ""
    @State private var gpxURL: URL?
    @State private var watchStart: WatchStartState = .idle

    enum WatchStartState: Equatable { case idle, starting, failed(String) }

    private var busy: Bool {
        tracking.state != .idle || mirror.isActive || watchStart == .starting
    }

    /// Launches the Watch app into this route's workout. The Watch records it (so it lands in
    /// Fitness with heart rate) and mirrors it back; the phone does not record ("one recorder").
    private func startOnWatch(_ route: RouteDTO) async {
        watchStart = .starting
        if let message = await services.startOnWatch(activity: route.activity, route: route) {
            watchStart = .failed(message)
        } else {
            watchStart = .idle
        }
    }

    var body: some View {
        let dto = route.dto
        List {
            Section {
                RouteShapeView(planned: dto.coords)
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                HStack {
                    Stat(title: "Distance", value: Format.distance(km: dto.distanceKm))
                    Stat(title: "Time", value: Format.minutes(dto.durationMin))
                    Stat(title: "Climb", value: dto.elevGainM.map { "\(Int($0.rounded())) m" } ?? "—")
                }
                if let elevation = dto.elevProfile, let interval = dto.elevationIntervalM {
                    ElevationChart(elevation: elevation, intervalM: interval)
                        .frame(height: 120)
                }
            }

            Section {
                if sync.canStartOnWatch {
                    Button {
                        Task { await startOnWatch(dto) }
                    } label: {
                        HStack {
                            Label("Start on Apple Watch", systemImage: "applewatch")
                            Spacer()
                            if watchStart == .starting { ProgressView() }
                        }
                    }
                    .disabled(busy)
                }
                Button("Start on iPhone", systemImage: "iphone") {
                    watchStart = .idle
                    tracking.start(route: dto, activity: dto.activity)
                }
                .disabled(busy)
                if case .failed(let message) = watchStart {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
                if mirror.isActive {
                    Text("A Watch workout is running. The Watch records; the phone shows it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(sync.canStartOnWatch
                     ? "Both save a \(dto.activity.title.lowercased()) workout with its route to Health and Fitness. Wearing your Watch? Start there: it records heart rate and the phone shows it live."
                     : "Saves a \(dto.activity.title.lowercased()) workout with its route to Health and Fitness.")
            }

            Section {
                Button("Edit in planner", systemImage: "pencil") {
                    services.planner.load(dto)
                    services.selectedTab = .plan
                }
                Button("Rename", systemImage: "character.cursor.ibeam") {
                    newName = route.name
                    renaming = true
                }
                if let gpxURL {
                    ShareLink(item: gpxURL) {
                        Label("Export GPX", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: route.updatedAt) { gpxURL = writeGPX(dto) }
        .alert("Rename route", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                guard !newName.isEmpty else { return }
                route.name = newName
                route.updatedAt = .now
                try? context.save()
                sync.routesChanged()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func writeGPX(_ dto: RouteDTO) -> URL? {
        let safe = dto.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(safe).gpx")
        do {
            try GPX.document(for: dto).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
