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
    private var latestHeartRate: (bpm: Double, at: Date)?

    weak var mirror: MirroredWorkout?

    private let health: HKHealthStore
    private let context: ModelContext
    private let liveActivity: LiveActivityController
    private let locationManager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private var updatesTask: Task<Void, Never>?
    private var heartRateTask: Task<Void, Never>?
    private var geometry: RouteGeometry?
    /// How far along the route we were at the last on-route fix (progress-aware matching).
    private var lastAlongM: Double?
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

    /// Latest heart rate another device wrote to Health during this workout (the iPhone has no
    /// sensor of its own). Nil when there is none, or the last reading is over a minute old.
    var heartRate: Double? {
        guard let latestHeartRate, Date.now.timeIntervalSince(latestHeartRate.at) < 60 else { return nil }
        return latestHeartRate.bpm
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
        lastAlongM = route == nil ? nil : 0
        remainingKm = route?.distanceKm
        detector.reset()
        isOffRoute = false
        track = TrackAccumulator(maxAccuracyM: 30)
        pendingRouteLocations = []
        latestHeartRate = nil
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

        heartRateTask = Task { [weak self, health] in
            for await sample in HealthVitals.heartRateUpdates(from: health, since: start) {
                guard let self, !Task.isCancelled else { break }
                self.latestHeartRate = sample
            }
        }

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

        if let geometry, let match = geometry.nearest(to: point.coordinate, after: lastAlongM) {
            if match.distanceM <= detector.thresholdM { lastAlongM = match.alongM }
            remainingKm = max(0, geometry.totalLengthM - (lastAlongM ?? match.alongM)) / 1000
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
              remainingKm: remainingKm, heartRate: heartRate, offRoute: isOffRoute, fromWatch: false)
    }

    func stop() async {
        guard state == .running, let startedAt else { return }
        state = .saving
        updatesTask?.cancel()
        updatesTask = nil
        heartRateTask?.cancel()
        heartRateTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        flushRouteData()
        let end = Date.now
        liveActivity.end(contentState)

        var healthUUID: UUID?
        var vitals = HealthVitals()
        if let recorder, track.points.count >= 2 {
            if let saved = await recorder.finish(at: end, distanceM: track.distanceM) {
                healthUUID = saved.uuid
                vitals = saved.vitals
            }
            // Whatever the workout did not collect itself, take from Health for the same span.
            if vitals.avgHR == nil || vitals.activeEnergyKcal == nil {
                vitals = vitals.filling(from: await HealthVitals.read(from: health, start: startedAt, end: end))
            }
        }
        recorder = nil

        if track.points.count >= 2 {
            let session = SessionDTO(
                routeId: route?.id, routeName: route?.name, activity: activity, start: startedAt, end: end,
                trackPoints: track.points, distanceKm: distanceKm, avgHR: vitals.avgHR,
                activeEnergyKcal: vitals.activeEnergyKcal,
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
        heartRateTask?.cancel()
        heartRateTask = nil
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
        latestHeartRate = nil
    }
}

/// Builds a Health workout (with its route) for a phone-recorded session, so the walk, hike or
/// run appears in Health and Fitness.
/// - iOS 26+: a live `HKWorkoutSession` with `HKLiveWorkoutBuilder`, so it is a real
///   in-progress workout on the iPhone (iOS 26 added workout sessions on iPhone).
/// - iOS 18-25: an `HKWorkoutBuilder`; the workout is saved when you stop.
final class PhoneWorkoutRecorder {
    private let health: HKHealthStore
    private let activity: ActivityKind
    private var builder: HKWorkoutBuilder
    private var session: HKWorkoutSession?
    private let routeBuilder: HKWorkoutRouteBuilder
    private var began = false

    init(health: HKHealthStore, activity: ActivityKind) {
        self.health = health
        self.activity = activity
        builder = HKWorkoutBuilder(healthStore: health, configuration: activity.workoutConfiguration, device: .local())
        routeBuilder = HKWorkoutRouteBuilder(healthStore: health, device: .local())
    }

    func begin(at date: Date) async {
        do {
            try await HealthTypes.requestAuthorization(health)
            if #available(iOS 26.0, *) {
                let configuration = activity.workoutConfiguration
                let session = try HKWorkoutSession(healthStore: health, configuration: configuration)
                let live = session.associatedWorkoutBuilder()
                live.dataSource = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: configuration)
                self.session = session
                builder = live
                session.startActivity(with: date)
            }
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

    /// Returns the UUID of the saved HKWorkout and the heart rate and energy it collected.
    func finish(at end: Date, distanceM: Double) async -> (uuid: UUID, vitals: HealthVitals)? {
        guard began else { return nil }
        do {
            if let session {
                session.stopActivity(with: end)
                session.end()
            }
            // A live builder may already have collected distance; only add ours if it has none.
            let collected = builder.statistics(for: HKQuantityType(.distanceWalkingRunning))?
                .sumQuantity()?.doubleValue(for: .meter()) ?? 0
            if collected <= 0 {
                let distance = HKQuantitySample(
                    type: HKQuantityType(.distanceWalkingRunning),
                    quantity: HKQuantity(unit: .meter(), doubleValue: distanceM),
                    start: builder.startDate ?? end, end: end
                )
                try await builder.addSamples([distance])
            }
            try await builder.endCollection(at: end)
            guard let workout = try await builder.finishWorkout() else { return nil }
            _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
            return (workout.uuid, HealthVitals(workout: workout))
        } catch {
            print("Workout save failed: \(error)")
            return nil
        }
    }

    func discard() {
        session?.end()
        builder.discardWorkout()
        routeBuilder.discard()
    }
}
