import Foundation

/// Off-route rule shared by the iPhone and the Watch: more than `thresholdM` away from the
/// planned route for `requiredFixes` fixes in a row. A single on-route fix clears it.
public struct OffRouteDetector: Sendable {
    public enum Transition: Sendable { case wentOffRoute, backOnRoute }

    public let thresholdM: Double
    public let requiredFixes: Int
    public private(set) var consecutiveOff = 0
    public private(set) var isOffRoute = false

    public init(thresholdM: Double = 30, requiredFixes: Int = 3) {
        self.thresholdM = thresholdM
        self.requiredFixes = requiredFixes
    }

    /// Feed the distance from the latest accepted fix to the route. Returns a transition when
    /// the state changes, so callers can fire a haptic exactly once.
    public mutating func update(distanceM: Double) -> Transition? {
        if distanceM > thresholdM {
            consecutiveOff += 1
            if !isOffRoute && consecutiveOff >= requiredFixes {
                isOffRoute = true
                return .wentOffRoute
            }
        } else {
            consecutiveOff = 0
            if isOffRoute {
                isOffRoute = false
                return .backOnRoute
            }
        }
        return nil
    }

    public mutating func reset() {
        consecutiveOff = 0
        isOffRoute = false
    }
}

/// Accumulates distance from accepted fixes. Rejects fixes worse than `maxAccuracyM`
/// and ignores jitter smaller than `minStepM` while standing still.
public struct TrackAccumulator: Sendable {
    public let maxAccuracyM: Double
    public let minStepM: Double
    public private(set) var points: [TrackPoint] = []
    public private(set) var distanceM: Double = 0

    public init(maxAccuracyM: Double = 30, minStepM: Double = 2) {
        self.maxAccuracyM = maxAccuracyM
        self.minStepM = minStepM
    }

    /// Returns true if the point was accepted.
    @discardableResult
    public mutating func add(_ p: TrackPoint) -> Bool {
        guard p.horizontalAccuracy >= 0, p.horizontalAccuracy <= maxAccuracyM else { return false }
        if let last = points.last {
            let step = Geo.distance(last.coordinate, p.coordinate)
            guard step >= minStepM else { return false }
            distanceM += step
        }
        points.append(p)
        return true
    }
}

public enum Format {
    public static func distance(km: Double) -> String {
        km < 1 ? "\(Int((km * 1000).rounded())) m" : String(format: "%.2f km", km)
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Pace as min:sec per km.
    public static func pace(secondsPerKm: Double?) -> String {
        guard let p = secondsPerKm, p.isFinite, p > 0, p < 3600 else { return "--:--" }
        return String(format: "%d:%02d /km", Int(p) / 60, Int(p) % 60)
    }

    public static func minutes(_ min: Double) -> String {
        min >= 60 ? String(format: "%dh %02dm", Int(min) / 60, Int(min) % 60) : "\(Int(min.rounded())) min"
    }
}
