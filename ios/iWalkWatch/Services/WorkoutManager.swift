import CoreLocation
import Foundation
import HealthKit
import WatchKit
import iWalkCore

/// Records a workout on the Watch with HKWorkoutSession + HKLiveWorkoutBuilder, the route with
/// HKWorkoutRouteBuilder, and mirrors it live to the iPhone. Works with the phone out of range.
@Observable
final class WorkoutManager: NSObject {
    enum Phase: Equatable { case idle, running, paused, ending, summary }

    private(set) var phase: Phase = .idle
    private(set) var route: RouteDTO?
    private(set) var activity: ActivityKind = .walk
    private(set) var heartRate: Double?
    private(set) var averageHeartRate: Double?
    private(set) var distanceKm: Double = 0
    private(set) var activeEnergyKcal: Double = 0
    private(set) var currentLocation: Coordinate?
    private(set) var remainingKm: Double?
    private(set) var isOffRoute = false
    private(set) var track = TrackAccumulator(maxAccuracyM: 30)
    private(set) var lastSession: SessionDTO?
    private(set) var lastError: String?

    /// Called with the finished session so it can be queued for the phone.
    var onFinished: ((SessionDTO) -> Void)?

    private let health = HKHealthStore()
    private let locationManager = CLLocationManager()
    private var session: HKWorkoutSession?
    private(set) var builder: HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    private var geometry: RouteGeometry?
    private var detector = OffRouteDetector()
    private var lastMirrorSend = Date.distantPast

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .fitness
        locationManager.distanceFilter = kCLDistanceFilterNone
    }

    func requestAuthorization() async {
        do {
            try await HealthTypes.requestAuthorization(health)
        } catch {
            lastError = "Health access failed: \(error.localizedDescription)"
        }
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func start(activity: ActivityKind, route: RouteDTO?) async {
        guard phase == .idle || phase == .summary else { return }
        await requestAuthorization()
        self.route = route
        self.activity = route?.activity ?? activity
        geometry = route.map { RouteGeometry($0.coords) }
        remainingKm = route?.distanceKm
        detector.reset()
        isOffRoute = false
        track = TrackAccumulator(maxAccuracyM: 30)
        heartRate = nil
        averageHeartRate = nil
        distanceKm = 0
        activeEnergyKcal = 0
        lastSession = nil
        lastError = nil

        let configuration = self.activity.workoutConfiguration
        do {
            let session = try HKWorkoutSession(healthStore: health, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            routeBuilder = HKWorkoutRouteBuilder(healthStore: health, device: nil)

            let start = Date.now
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            phase = .running
            locationManager.startUpdatingLocation()

            // Live stats on the iPhone when it is in range. Recording does not depend on it.
            do {
                try await session.startMirroringToCompanionDevice()
            } catch {
                print("Mirroring unavailable: \(error)")
            }
        } catch {
            lastError = "Could not start the workout: \(error.localizedDescription)"
            phase = .idle
        }
    }

    func pause() { session?.pause() }
    func resume() { session?.resume() }

    func end() {
        guard let session, phase == .running || phase == .paused else { return }
        phase = .ending
        locationManager.stopUpdatingLocation()
        session.stopActivity(with: .now)
        session.end()
    }

    func dismissSummary() {
        phase = .idle
        route = nil
    }

    // MARK: - Updates from delegates (main actor)

    fileprivate func handle(state: HKWorkoutSessionState, date: Date) {
        switch state {
        case .running:
            if phase == .paused { phase = .running; sendMirrorUpdate(force: true) }
        case .paused:
            if phase == .running { phase = .paused; sendMirrorUpdate(force: true) }
        case .ended: Task { await finish(at: date) }
        default: break
        }
    }

    fileprivate func handle(locations: [CLLocation]) {
        guard phase == .running else { return }
        var accepted: [CLLocation] = []
        for location in locations where track.add(TrackPoint(location)) {
            accepted.append(location)
        }
        guard let last = accepted.last else { return }
        let point = Coordinate(last.coordinate)
        currentLocation = point
        if let routeBuilder {
            Task {
                do { try await routeBuilder.insertRouteData(accepted) } catch { print("Route insert failed: \(error)") }
            }
        }

        var changed = false
        if let geometry, let match = geometry.nearest(to: point) {
            remainingKm = max(0, geometry.totalLengthM - match.alongM) / 1000
            switch detector.update(distanceM: match.distanceM) {
            case .wentOffRoute:
                isOffRoute = true
                changed = true
                WKInterfaceDevice.current().play(.notification)
            case .backOnRoute:
                isOffRoute = false
                changed = true
                WKInterfaceDevice.current().play(.success)
            case nil:
                break
            }
        }
        sendMirrorUpdate(force: changed)
    }

    fileprivate func handle(distanceKm: Double?, heartRate: Double?, averageHeartRate: Double?, energy: Double?) {
        if let distanceKm { self.distanceKm = distanceKm }
        if let heartRate { self.heartRate = heartRate }
        if let averageHeartRate { self.averageHeartRate = averageHeartRate }
        if let energy { activeEnergyKcal = energy }
        // Heart rate keeps the phone's view fresh even when standing still (no new GPS fixes).
        sendMirrorUpdate(force: false)
    }

    private func sendMirrorUpdate(force: Bool) {
        guard let session, phase == .running || phase == .paused,
              force || Date.now.timeIntervalSince(lastMirrorSend) >= 5 else { return }
        lastMirrorSend = .now
        let update = MirrorUpdate(routeId: route?.id, routeName: route?.name, activity: activity,
                                  elapsedS: builder?.elapsedTime ?? 0, isPaused: phase == .paused,
                                  distanceKm: distanceKm, heartRate: heartRate, activeEnergyKcal: activeEnergyKcal,
                                  latitude: currentLocation?.latitude, longitude: currentLocation?.longitude,
                                  remainingKm: remainingKm, offRoute: isOffRoute)
        guard let data = try? JSONCoding.encoder.encode(update) else { return }
        Task {
            do { try await session.sendToRemoteWorkoutSession(data: data) } catch { /* phone out of range */ }
        }
    }

    private func finish(at end: Date) async {
        guard let builder, let session else { return }
        do {
            try await builder.endCollection(at: end)
            guard let workout = try await builder.finishWorkout() else {
                throw NSError(domain: "iWalk", code: 1, userInfo: [NSLocalizedDescriptionKey: "No workout was saved."])
            }
            if let routeBuilder, track.points.count >= 2 {
                _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
            }
            let distanceKm = workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?
                .sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo)) ?? track.distanceM / 1000
            let dto = SessionDTO(
                routeId: route?.id, routeName: route?.name, activity: activity,
                start: session.startDate ?? workout.startDate, end: workout.endDate,
                trackPoints: track.points, distanceKm: distanceKm, avgHR: averageHeartRate,
                activeEnergyKcal: activeEnergyKcal, healthKitUUID: workout.uuid, source: .watch
            )
            lastSession = dto
            onFinished?(dto)
        } catch {
            lastError = "Saving failed: \(error.localizedDescription)"
        }
        self.session = nil
        self.builder = nil
        routeBuilder = nil
        phase = .summary
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in self.handle(state: toState, date: date) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.lastError = message }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let hrStats = workoutBuilder.statistics(for: HKQuantityType(.heartRate))
        let distance = workoutBuilder.statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo))
        let hr = hrStats?.mostRecentQuantity()?.doubleValue(for: bpm)
        let avg = hrStats?.averageQuantity()?.doubleValue(for: bpm)
        let energy = workoutBuilder.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie())
        Task { @MainActor in
            self.handle(distanceKm: distance, heartRate: hr, averageHeartRate: avg, energy: energy)
        }
    }
}

extension WorkoutManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.handle(locations: locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error)")
    }
}
