import Foundation

/// Phone → Watch: the whole route list. The Watch applies it only if `version` is newer
/// than what it has, then replaces its store, so deletes carry over.
public struct RouteBundle: Codable, Sendable {
    public var version: Int
    public var routes: [RouteDTO]

    public init(version: Int, routes: [RouteDTO]) {
        self.version = version
        self.routes = routes
    }
}

/// Keys for WatchConnectivity file metadata and user-info dictionaries.
public enum SyncKey {
    public static let kind = "kind"
    public static let version = "version"
    public static let sessionId = "sessionId"
    public static let ackRouteVersion = "ackRouteVersion"

    public enum Kind {
        public static let routeBundle = "routeBundle"
        public static let session = "session"
    }
}

/// Live update the Watch sends to the iPhone over the mirrored workout session
/// (`sendToRemoteWorkoutSession`, iOS 17+). It carries all live stats, because the mirrored
/// `associatedWorkoutBuilder()` on iPhone needs iOS 26 and iWalk targets iOS 18.
public struct MirrorUpdate: Codable, Sendable {
    public var routeId: UUID?
    public var routeName: String?
    public var activity: ActivityKind
    public var sentAt: Date
    public var elapsedS: Double
    public var isPaused: Bool
    public var distanceKm: Double
    public var heartRate: Double?
    public var activeEnergyKcal: Double?
    public var latitude: Double?
    public var longitude: Double?
    public var remainingKm: Double?
    public var offRoute: Bool

    public init(routeId: UUID?, routeName: String?, activity: ActivityKind, sentAt: Date = .now, elapsedS: Double,
                isPaused: Bool, distanceKm: Double, heartRate: Double?, activeEnergyKcal: Double?,
                latitude: Double?, longitude: Double?, remainingKm: Double?, offRoute: Bool) {
        self.routeId = routeId
        self.routeName = routeName
        self.activity = activity
        self.sentAt = sentAt
        self.elapsedS = elapsedS
        self.isPaused = isPaused
        self.distanceKm = distanceKm
        self.heartRate = heartRate
        self.activeEnergyKcal = activeEnergyKcal
        self.latitude = latitude
        self.longitude = longitude
        self.remainingKm = remainingKm
        self.offRoute = offRoute
    }
}

/// GPX 1.1 export for a planned route.
public enum GPX {
    public static func document(for route: RouteDTO) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="iWalk" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>\(escape(route.name))</name></metadata>
          <trk>
            <name>\(escape(route.name))</name>
            <type>\(route.activity.rawValue)</type>
            <trkseg>

        """
        let elevation = route.elevProfile
        let geometry = RouteGeometry(route.coords)
        for (i, c) in route.coords.enumerated() {
            s += "      <trkpt lat=\"\(c.latitude)\" lon=\"\(c.longitude)\">"
            if let elevation, let interval = route.elevationIntervalM, interval > 0, !elevation.isEmpty {
                let idx = min(elevation.count - 1, Int((geometry.cumulative[i] / interval).rounded()))
                s += "<ele>\(String(format: "%.1f", elevation[idx]))</ele>"
            }
            s += "</trkpt>\n"
        }
        s += "    </trkseg>\n  </trk>\n</gpx>\n"
        return s
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
