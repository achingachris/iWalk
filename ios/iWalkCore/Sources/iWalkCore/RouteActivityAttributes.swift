#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity shared by the iOS app (which starts and updates it) and the widget
/// extension (which draws it). Updated locally from the location loop; no push.
public struct RouteActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var startedAt: Date
        public var distanceKm: Double
        public var paceSecPerKm: Double?
        public var remainingKm: Double?
        public var heartRate: Double?
        public var offRoute: Bool
        /// True when the numbers come from a Watch workout mirrored to the phone.
        public var fromWatch: Bool

        public init(startedAt: Date, distanceKm: Double, paceSecPerKm: Double?, remainingKm: Double?,
                    heartRate: Double?, offRoute: Bool, fromWatch: Bool) {
            self.startedAt = startedAt
            self.distanceKm = distanceKm
            self.paceSecPerKm = paceSecPerKm
            self.remainingKm = remainingKm
            self.heartRate = heartRate
            self.offRoute = offRoute
            self.fromWatch = fromWatch
        }
    }

    public var routeName: String
    public var activity: ActivityKind

    public init(routeName: String, activity: ActivityKind) {
        self.routeName = routeName
        self.activity = activity
    }
}
#endif
