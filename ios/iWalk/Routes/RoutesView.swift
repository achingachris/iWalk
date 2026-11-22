import SwiftData
import SwiftUI
import iWalkCore
import iWalkStore

struct RoutesView: View {
    @Query(sort: \RouteRecord.updatedAt, order: .reverse) private var routes: [RouteRecord]
    @Environment(\.modelContext) private var context
    @Environment(PhoneSync.self) private var sync

    var body: some View {
        NavigationStack {
            List {
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
                                           description: Text("Plan a route while online, then save it."))
                }
            }
            .navigationTitle("Routes")
            .navigationDestination(for: UUID.self) { id in
                if let route = routes.first(where: { $0.id == id }) {
                    RouteDetailView(route: route)
                }
            }
        }
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
                Button("Start on iPhone", systemImage: "play.fill") {
                    tracking.start(route: dto, activity: dto.activity)
                }
                .disabled(tracking.state != .idle || mirror.isActive)
                if mirror.isActive {
                    Text("A Watch workout is running. The Watch records; the phone shows it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Wearing your Watch? Start the route on the Watch instead. The phone will show it live.")
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
