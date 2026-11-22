import Foundation
import SwiftData
import iWalkCore
import iWalkStore

/// Checks finished walks against the saved route they followed. When a walk took a different
/// path, it snaps the walked track to OSM paths online (Valhalla `/trace_route`, with elevation)
/// and offers it as a replacement for the saved route.
///
/// - The comparison runs on the device, so it works offline.
/// - Snapping waits until the phone is online; sessions stay unchecked until then.
/// - Nothing changes the saved route until the user picks Update or Save as new route.
@Observable
final class RouteReviewer {
    enum Decision { case updateRoute, saveAsNewRoute, keepOriginal }

    private(set) var isChecking = false
    private(set) var lastError: String?

    private let context: ModelContext
    private let sync: PhoneSync
    private let network: NetworkMonitor

    init(context: ModelContext, sync: PhoneSync, network: NetworkMonitor) {
        self.context = context
        self.sync = sync
        self.network = network
    }

    /// Walks shorter than this don't become routes (quick tests, false starts).
    static let minimumNewRouteM = 200.0

    /// Reviews every finished walk that hasn't been checked yet: walks that followed a route are
    /// compared with it, and walks without a route are saved as new routes.
    func reviewPending() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let unchecked = (try? context.fetch(FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.routeReviewRaw == nil },
            sortBy: [SortDescriptor(\.start)]
        ))) ?? []

        var routesChanged = relinkDuplicateRoutes()
        for session in unchecked {
            if session.routeId == nil {
                // A walk started without a route: if it mostly followed a saved route, treat it
                // as a walk of that route (and review the differences) rather than a new route.
                if let match = bestMatchingRoute(for: session.trackPoints.map(\.coordinate)) {
                    session.routeId = match.id
                    session.routeName = match.name
                } else {
                    if await createRoute(from: session) { routesChanged = true }
                    continue
                }
            }
            guard let routeId = session.routeId,
                  let route = try? context.fetch(FetchDescriptor<RouteRecord>(
                      predicate: #Predicate { $0.id == routeId })).first else {
                session.routeReview = .dismissed   // the route was deleted
                continue
            }
            let track = session.trackPoints.map(\.coordinate)
            let comparison = RouteComparison.compare(track: track, planned: RouteGeometry(route.coords))
            guard comparison.differs else {
                session.routeReview = .matched
                continue
            }
            // Different path: snapping needs the server. Leave it unchecked until online.
            guard network.isOnline, let valhalla = AppConfig.makeValhalla() else { continue }
            do {
                let snapped = try await valhalla.snap(track: track, activity: session.activity)
                // Never offer a stub as a replacement route.
                guard snapped.coords.count >= 2, snapped.distanceKm >= 0.05 else {
                    session.routeReview = .dismissed
                    continue
                }
                session.routeProposal = proposal(from: snapped, replacing: route.dto)
                session.routeReview = .pending
                lastError = nil
            } catch {
                lastError = "Couldn't check a walk against its route: \(error.localizedDescription)"
            }
        }
        try? context.save()
        if routesChanged { sync.routesChanged() }   // new routes go to the Watch too
    }

    /// The saved route a track mostly followed: at least half of the walk within 40 m of it.
    /// Picks the closest fit when several qualify.
    private func bestMatchingRoute(for track: [Coordinate], excluding excluded: UUID? = nil) -> RouteRecord? {
        guard Geo.length(of: track) >= Self.minimumNewRouteM,
              let routes = try? context.fetch(FetchDescriptor<RouteRecord>()) else { return nil }
        var best: (route: RouteRecord, onRoute: Double)?
        for route in routes where route.id != excluded {
            let coords = route.coords
            guard coords.count > 1 else { continue }
            let result = RouteComparison.compare(track: track, planned: RouteGeometry(coords))
            guard result.trackM > 0 else { continue }
            let onRoute = 1 - result.offRouteM / result.trackM
            if onRoute >= 0.5, onRoute > (best?.onRoute ?? 0) { best = (route, onRoute) }
        }
        return best?.route
    }

    /// Repairs walks that were saved as a new route although they mostly followed an existing
    /// one (for example a Watch workout that started before its route arrived). The duplicate is
    /// removed only if it hasn't been touched since it was created; the walk is linked to the
    /// original route and its path is offered as an update (Update / Save as new / Keep).
    private func relinkDuplicateRoutes() -> Bool {
        let created = (try? context.fetch(FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.routeReviewRaw == "created" }))) ?? []
        var changed = false
        for session in created {
            guard let id = session.routeId,
                  let duplicate = try? context.fetch(FetchDescriptor<RouteRecord>(
                      predicate: #Predicate { $0.id == id })).first,
                  duplicate.updatedAt <= session.end.addingTimeInterval(15 * 60),
                  let original = bestMatchingRoute(for: session.trackPoints.map(\.coordinate), excluding: id)
            else { continue }
            var proposal = duplicate.dto          // already snapped to OSM paths, with elevation
            proposal.id = original.id
            proposal.name = original.name
            proposal.activity = original.activity
            session.routeProposal = proposal
            session.routeId = original.id
            session.routeName = original.name
            let walked = RouteComparison.compare(track: session.trackPoints.map(\.coordinate),
                                                 planned: RouteGeometry(original.coords))
            session.routeReview = walked.differs ? .pending : .matched
            context.delete(duplicate)
            changed = true
        }
        return changed
    }

    /// Saves a walk that had no planned route as a new route: the track snapped to OSM paths,
    /// with distance, time and elevation. Returns true if a route was created.
    private func createRoute(from session: SessionRecord) async -> Bool {
        let track = session.trackPoints.map(\.coordinate)
        guard Geo.length(of: track) >= Self.minimumNewRouteM else {
            session.routeReview = .dismissed   // too short to be worth a route
            return false
        }
        // Snapping needs the server. Leave it unchecked until online.
        guard network.isOnline, let valhalla = AppConfig.makeValhalla() else { return false }
        do {
            let snapped = try await valhalla.snap(track: track, activity: session.activity)
            guard snapped.coords.count >= 2, snapped.distanceKm >= 0.05 else {
                session.routeReview = .dismissed
                return false
            }
            let f = DateFormatter()
            f.dateFormat = "d MMM HH:mm"
            let template = RouteDTO(id: UUID(), name: "\(session.activity.title) \(f.string(from: session.start))",
                                    activity: session.activity, waypoints: [], isLoop: false, coords: [],
                                    distanceKm: 0, durationMin: 0, elevGainM: nil, elevProfile: nil,
                                    elevationIntervalM: nil)
            let route = proposal(from: snapped, replacing: template)
            context.insert(RouteRecord(route))
            // Link the walk to its new route, so History shows the name and future walks can follow it.
            session.routeId = route.id
            session.routeName = route.name
            session.routeReview = .created
            lastError = nil
            return true
        } catch {
            lastError = "Couldn't save a walk as a route: \(error.localizedDescription)"
            return false
        }
    }

    /// The walked path as a route, keeping the original's id, name and activity.
    private func proposal(from snapped: PlannedRoute, replacing route: RouteDTO) -> RouteDTO {
        var coords = snapped.coords
        let isLoop = coords.count > 2 && Geo.distance(coords[0], coords[coords.count - 1]) < 50
        var waypoints = Geo.waypoints(along: coords)
        if isLoop, waypoints.count > 2 {
            waypoints.removeLast()   // the planner closes loops itself
            coords[coords.count - 1] = coords[0]
        }
        return RouteDTO(
            id: route.id, name: route.name, activity: route.activity, waypoints: waypoints, isLoop: isLoop,
            coords: coords, distanceKm: snapped.distanceKm, durationMin: snapped.durationMin,
            elevGainM: snapped.elevGainM, elevProfile: snapped.elevation,
            elevationIntervalM: snapped.elevationIntervalM, updatedAt: .now
        )
    }

    func decide(_ decision: Decision, for session: SessionRecord) {
        guard let proposal = session.routeProposal else { return }
        do {
            switch decision {
            case .updateRoute:
                let id = proposal.id
                if let route = try context.fetch(FetchDescriptor<RouteRecord>(predicate: #Predicate { $0.id == id })).first {
                    route.update(from: proposal)
                } else {
                    context.insert(RouteRecord(proposal))
                }
                session.routeReview = .applied
            case .saveAsNewRoute:
                var copy = proposal
                copy.id = UUID()
                copy.name = "\(proposal.name) (walked)"
                context.insert(RouteRecord(copy))
                session.routeReview = .applied
            case .keepOriginal:
                session.routeReview = .dismissed
            }
            try context.save()
            if decision != .keepOriginal { sync.routesChanged() }   // the Watch gets the new version
        } catch {
            lastError = "Couldn't save the route: \(error.localizedDescription)"
        }
    }
}
