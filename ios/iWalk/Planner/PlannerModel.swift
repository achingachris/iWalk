import Foundation
import SwiftData
import iWalkCore
import iWalkStore

/// State for the route planner: waypoints, activity, loop, the planned result, and saving.
@Observable
final class PlannerModel {
    var waypoints: [Coordinate] = [] { didSet { scheduleRecalc() } }
    var activity: ActivityKind = .walk { didSet { scheduleRecalc() } }
    var isLoop = false { didSet { scheduleRecalc() } }

    private(set) var planned: PlannedRoute?
    private(set) var isPlanning = false
    private(set) var error: String?
    /// Set when editing a saved route, so saving updates it instead of creating a new one.
    private(set) var editingRoute: RouteDTO?

    private var recalcTask: Task<Void, Never>?
    private let planner: any RoutePlanner = AppConfig.makePlanner()

    var canSave: Bool { planned != nil && !isPlanning }

    private var routedPoints: [Coordinate] {
        guard isLoop, let first = waypoints.first, waypoints.count >= 2 else { return waypoints }
        return waypoints + [first]
    }

    func add(_ c: Coordinate) { waypoints.append(c) }
    func move(at index: Int, to c: Coordinate) {
        guard waypoints.indices.contains(index) else { return }
        waypoints[index] = c
    }
    func remove(at index: Int) {
        guard waypoints.indices.contains(index) else { return }
        waypoints.remove(at: index)
    }
    func undo() { if !waypoints.isEmpty { waypoints.removeLast() } }

    func clear() {
        editingRoute = nil
        waypoints = []
        planned = nil
        error = nil
    }

    func load(_ route: RouteDTO) {
        editingRoute = route
        activity = route.activity
        isLoop = route.isLoop
        waypoints = route.waypoints
    }

    /// Debounced so dragging a point does not fire a request per frame.
    private func scheduleRecalc() {
        recalcTask?.cancel()
        let points = routedPoints
        let activity = activity
        guard points.count >= 2 else {
            planned = nil
            isPlanning = false
            return
        }
        recalcTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.isPlanning = true
            self.error = nil
            do {
                let result = try await self.planner.plan(waypoints: points, activity: activity)
                guard !Task.isCancelled else { return }
                self.planned = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self.isPlanning = false
        }
    }

    var suggestedName: String {
        if let editingRoute { return editingRoute.name }
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return "\(activity.title) \(f.string(from: .now))"
    }

    /// Saves (or updates) the route and tells the sync layer. Returns the saved route.
    @discardableResult
    func save(name: String, context: ModelContext, sync: PhoneSync) throws -> RouteDTO? {
        guard let planned else { return nil }
        let dto = RouteDTO(
            id: editingRoute?.id ?? UUID(),
            name: name.isEmpty ? suggestedName : name,
            activity: activity, waypoints: waypoints, isLoop: isLoop, coords: planned.coords,
            distanceKm: planned.distanceKm, durationMin: planned.durationMin, elevGainM: planned.elevGainM,
            elevProfile: planned.elevation, elevationIntervalM: planned.elevationIntervalM, updatedAt: .now
        )
        let id = dto.id
        if let existing = try context.fetch(FetchDescriptor<RouteRecord>(predicate: #Predicate { $0.id == id })).first {
            existing.update(from: dto)
        } else {
            context.insert(RouteRecord(dto))
        }
        try context.save()
        sync.routesChanged()
        editingRoute = dto
        return dto
    }
}
