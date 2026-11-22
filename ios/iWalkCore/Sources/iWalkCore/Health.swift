import Foundation
import HealthKit

/// HealthKit types iWalk shares and reads, on both the iPhone and the Watch.
public enum HealthTypes {
    public static var share: Set<HKSampleType> {
        [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.activeEnergyBurned),
        ]
    }

    public static var read: Set<HKObjectType> {
        [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.heartRate),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.activeEnergyBurned),
        ]
    }

    public static func requestAuthorization(_ store: HKHealthStore) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: share, read: read)
    }
}

extension ActivityKind {
    public var workoutActivityType: HKWorkoutActivityType {
        switch self {
        case .walk: .walking
        case .hike: .hiking
        case .run: .running
        }
    }

    public init(workoutActivityType: HKWorkoutActivityType) {
        switch workoutActivityType {
        case .hiking: self = .hike
        case .running: self = .run
        default: self = .walk
        }
    }

    public var workoutConfiguration: HKWorkoutConfiguration {
        let c = HKWorkoutConfiguration()
        c.activityType = workoutActivityType
        c.locationType = .outdoor
        return c
    }
}

/// Heart rate and active energy read back from Health for a time span. The iPhone has no
/// heart-rate sensor, so for a phone-recorded workout these come from whatever else writes to
/// Health: an Apple Watch, AirPods with heart-rate sensing, a Bluetooth chest strap, and the
/// iPhone's own motion-based active-energy estimate.
public struct HealthVitals: Sendable, Equatable {
    public var avgHR: Double?
    public var activeEnergyKcal: Double?

    public init(avgHR: Double? = nil, activeEnergyKcal: Double? = nil) {
        self.avgHR = avgHR
        self.activeEnergyKcal = activeEnergyKcal
    }

    public static let bpm = HKUnit.count().unitDivided(by: .minute())

    /// What a finished workout itself collected (a live builder gathers these while it runs).
    public init(workout: HKWorkout) {
        avgHR = workout.statistics(for: HKQuantityType(.heartRate))?
            .averageQuantity()?.doubleValue(for: Self.bpm)
        activeEnergyKcal = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie())
        if let kcal = activeEnergyKcal, kcal <= 0 { activeEnergyKcal = nil }
    }

    /// Fills any missing value from `other`.
    public func filling(from other: HealthVitals) -> HealthVitals {
        HealthVitals(avgHR: avgHR ?? other.avgHR, activeEnergyKcal: activeEnergyKcal ?? other.activeEnergyKcal)
    }

    /// Average heart rate and total active energy of all Health samples between `start` and `end`.
    /// A value is nil when Health has no samples for it (or read access was not granted).
    public static func read(from store: HKHealthStore, start: Date, end: Date) async -> HealthVitals {
        guard HKHealthStore.isHealthDataAvailable(), end > start else { return HealthVitals() }
        let span = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let heartRate = try? await HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.heartRate), predicate: span),
            options: .discreteAverage
        ).result(for: store)
        let energy = try? await HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.activeEnergyBurned), predicate: span),
            options: .cumulativeSum
        ).result(for: store)
        var vitals = HealthVitals(
            avgHR: heartRate?.averageQuantity()?.doubleValue(for: bpm),
            activeEnergyKcal: energy?.sumQuantity()?.doubleValue(for: .kilocalorie())
        )
        if let kcal = vitals.activeEnergyKcal, kcal <= 0 { vitals.activeEnergyKcal = nil }
        return vitals
    }

    /// Live heart rate: every new Health sample from `start` on, newest first seen. Ends when the
    /// task is cancelled. Yields nothing if no device is writing heart rate.
    public static func heartRateUpdates(from store: HKHealthStore, since start: Date) -> AsyncStream<(bpm: Double, at: Date)> {
        AsyncStream { continuation in
            guard HKHealthStore.isHealthDataAvailable() else {
                continuation.finish()
                return
            }
            let task = Task {
                let descriptor = HKAnchoredObjectQueryDescriptor(
                    predicates: [.quantitySample(type: HKQuantityType(.heartRate),
                                                 predicate: HKQuery.predicateForSamples(withStart: start, end: nil))],
                    anchor: nil
                )
                do {
                    for try await result in descriptor.results(for: store) {
                        if let latest = result.addedSamples.max(by: { $0.endDate < $1.endDate }) {
                            continuation.yield((latest.quantity.doubleValue(for: bpm), latest.endDate))
                        }
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
