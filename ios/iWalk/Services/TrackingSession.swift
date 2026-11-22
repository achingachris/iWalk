import CoreLocation
import Foundation
import HealthKit
import SwiftData
import UIKit
import iWalkCore
import iWalkStore

/// Records a walk on the iPhone with no internet: background GPS via CLBackgroundActivitySession,
/// live stats, off-route alerts, the Live Activity, and a Health workout with its route at the end.
/// Only used when no Watch workout is running ("one recorder per workout").
@Observable
final class TrackingSession {
    enum State: Equatable { case idle, running, saving }

    private(set) var state: State = .idle
    private(set) var route: RouteDTO?
    private(set) var activity: ActivityKind = .walk
    private(set) var startedAt: Date?
    private(set) var track = TrackAccumulator(maxAccuracyM: 30)
    private(set) var currentLocation: Coordinate?
    private(set) var remainingKm: Double?
    private(set) var isOffRoute = false
    private(set) var lastAccuracyM: Double?
    private(set) var lastError: String?

    weak var mirror: MirroredWorkout?

    private let health: HKHealthStore
    private let context: ModelContext
    private let liveActivity: LiveActivityController
    private let locationManager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private var updatesTask: Task<Void, Never>?
    private var geometry: RouteGeometry?
    private var detector = OffRouteDetector()
    private var recorder: PhoneWorkoutRecorder?
    private var pendingRouteLocations: [CLLocation] = []

    init(health: HKHealthStore, context: ModelContext, liveActivity: LiveActivityController) {
        self.health = health
        self.context = context
        self.liveActivity = liveActivity
    }

    var distanceKm: Double { track.distanceM / 1000 }

    var averagePaceSecPerKm: Double? {
        guard let startedAt, track.distanceM > 20 else { return nil }
        return Date.now.timeIntervalSince(startedAt) / distanceKm
    }

    /// Pace over the last minute of accepted fixes.
    var currentPaceSecPerKm: Double? {
        let pts = track.points
        guard let last = pts.last else { return nil }
        let window = pts.reversed().prefix { last.timestamp.timeIntervalSince($0.timestamp) <= 60 }
        guard let oldest = window.last, window.count > 2 else { return nil }
        let dist = Geo.length(of: window.reversed().map(\.coordinate))
        guard dist > 10 else { return nil }
        return last.timestamp.timeIntervalSince(oldest.timestamp) / (dist / 1000)
    }

    /// Call from a button tap: the background session and Live Activity must start on screen.
    func start(route: RouteDTO?, activity: ActivityKind) {
        guard state == .idle else { return }
        if mirror?.isActive == true {
            lastError = "A Watch workout is running. The Watch is recording it."
            return
        }
        lastError = nil
        self.route = route
        self.activity = route?.activity ?? activity
        geometry = route.map { RouteGeometry($0.coords) }
        remainingKm = route?.distanceKm
        detector.reset()
        isOffRoute = false
        track = TrackAccumulator(maxAccuracyM: 30)
        pendingRouteLocations = []
        let start = Date.now
        startedAt = start
        state = .running

        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        backgroundSession = CLBackgroundActivitySession()

        recorder = PhoneWorkoutRecorder(health: health, activity: self.activity)
        Task { await recorder?.begin(at: start) }

        liveActivity.start(routeName: route?.name ?? "\(self.activity.title)", activity: self.activity,
                           state: contentState)

        updatesTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                    guard let self, !Task.isCancelled else { break }
                    if let location = update.location { self.handle(location) }
                }
            } catch {
                self?.lastError = "Location updates stopped: \(error.localizedDescription)"
            }
        }
    }

    private func handle(_ location: CLLocation) {
        lastAccuracyM = location.horizontalAccuracy
        let point = TrackPoint(location)
        guard track.add(point) else { return }
        currentLocation = point.coordinate

        pendingRouteLocations.append(location)
        if pendingRouteLocations.count >= 10 { flushRouteData() }

        if let geometry, let match = geometry.nearest(to: point.coordinate) {
            remainingKm = max(0, geometry.totalLengthM - match.alongM) / 1000
            switch detector.update(distanceM: match.distanceM) {
            case .wentOffRoute:
                isOffRoute = true
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                liveActivity.update(contentState, force: true)
                return
            case .backOnRoute:
                isOffRoute = false
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                liveActivity.update(contentState, force: true)
                return
            case nil:
                break
            }
        }
        liveActivity.update(contentState)
    }

    private func flushRouteData() {
        let batch = pendingRouteLocations
        pendingRouteLocations = []
        guard !batch.isEmpty, let recorder else { return }
        Task { await recorder.insert(batch) }
    }

    var contentState: RouteActivityAttributes.ContentState {
        .init(startedAt: startedAt ?? .now, distanceKm: distanceKm, paceSecPerKm: currentPaceSecPerKm ?? averagePaceSecPerKm,
              remainingKm: remainingKm, heartRate: nil, offRoute: isOffRoute, fromWatch: false)
    }

    func stop() async {
        guard state == .running, let startedAt else { return }
        state = .saving
        updatesTask?.cancel()
        updatesTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        flushRouteData()
        let end = Date.now
        liveActivity.end(contentState)

        var healthUUID: UUID?
        if let recorder, track.points.count >= 2 {
            healthUUID = await recorder.finish(at: end, distanceM: track.distanceM)
        }
        recorder = nil

        if track.points.count >= 2 {
            let session = SessionDTO(
                routeId: route?.id, routeName: route?.name, activity: activity, start: startedAt, end: end,
                trackPoints: track.points, distanceKm: distanceKm, avgHR: nil, activeEnergyKcal: nil,
                healthKitUUID: healthUUID, source: .phone
            )
            do {
                try context.upsertSession(session)
            } catch {
                lastError = "Could not save the session: \(error.localizedDescription)"
            }
        }
        reset()
    }

    func discard() {
        updatesTask?.cancel()
        backgroundSession?.invalidate()
        backgroundSession = nil
        liveActivity.end(nil)
        recorder?.discard()
        recorder = nil
        reset()
    }

    private func reset() {
        state = .idle
        route = nil
        geometry = nil
        startedAt = nil
        currentLocation = nil
        remainingKm = nil
        isOffRoute = false
    }
}

/// Builds a Health workout (with its route) for a phone-recorded session.
final class PhoneWorkoutRecorder {
    private let health: HKHealthStore
    private let builder: HKWorkoutBuilder
    private let routeBuilder: HKWorkoutRouteBuilder
    private var began = false

    init(health: HKHealthStore, activity: ActivityKind) {
        self.health = health
        builder = HKWorkoutBuilder(healthStore: health, configuration: activity.workoutConfiguration, device: .local())
        routeBuilder = HKWorkoutRouteBuilder(healthStore: health, device: .local())
    }

    func begin(at date: Date) async {
        do {
            try await HealthTypes.requestAuthorization(health)
            try await builder.beginCollection(at: date)
            began = true
        } catch {
            print("Workout begin failed: \(error)")
        }
    }

    func insert(_ locations: [CLLocation]) async {
        do {
            try await routeBuilder.insertRouteData(locations)
        } catch {
            print("Route insert failed: \(error)")
        }
    }

    /// Returns the UUID of the saved HKWorkout.
    func finish(at end: Date, distanceM: Double) async -> UUID? {
        guard began else { return nil }
        do {
            let start = builder.startDate ?? end
            let distance = HKQuantitySample(
                type: HKQuantityType(.distanceWalkingRunning),
                quantity: HKQuantity(unit: .meter(), doubleValue: distanceM),
                start: start, end: end
            )
            try await builder.addSamples([distance])
            try await builder.endCollection(at: end)
            guard let workout = try await builder.finishWorkout() else { return nil }
            _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
            return workout.uuid
        } catch {
            print("Workout save failed: \(error)")
            return nil
        }
    }

    func discard() {
        builder.discardWorkout()
        routeBuilder.discard()
    }
}
