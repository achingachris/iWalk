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
