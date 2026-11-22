import Foundation
import CoreLocation

/// A plain, Codable coordinate. Used everywhere instead of CLLocationCoordinate2D
/// so routes and sessions can be stored and sent over WatchConnectivity as JSON.
public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ c: CLLocationCoordinate2D) {
        self.init(latitude: c.latitude, longitude: c.longitude)
    }

    public var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Walk, hike or run. Drives Valhalla costing, HealthKit activity type and UI.
public enum ActivityKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case walk, hike, run

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .walk: "Walk"
        case .hike: "Hike"
        case .run: "Run"
        }
    }

    public var systemImage: String {
        switch self {
        case .walk: "figure.walk"
        case .hike: "figure.hiking"
        case .run: "figure.run"
        }
    }

    /// Valhalla `costing_options.pedestrian` for this activity.
    public var pedestrianCostingOptions: [String: Double] {
        switch self {
        case .walk: [:]
        case .hike: ["max_hiking_difficulty": 4, "use_tracks": 1.0, "use_hills": 0.8]
        case .run: ["walking_speed": 9.5]
        }
    }

    /// Speed used to scale durations when the planner does not know the activity (km/h).
    public var nominalSpeedKmh: Double {
        switch self {
        case .walk: 5.1
        case .hike: 4.0
        case .run: 9.5
        }
    }
}

/// A planned route. Owned by the iPhone: created, edited and deleted there, read-only on the Watch.
public struct RouteDTO: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var activity: ActivityKind
    /// The points the user placed. Kept so a route can be reopened and edited.
    public var waypoints: [Coordinate]
    public var isLoop: Bool
    /// The full routed geometry.
    public var coords: [Coordinate]
    public var distanceKm: Double
    public var durationMin: Double
    public var elevGainM: Double?
    /// Elevation samples in metres, one every `elevationIntervalM` along the route.
    public var elevProfile: [Double]?
    public var elevationIntervalM: Double?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, activity: ActivityKind, waypoints: [Coordinate], isLoop: Bool,
        coords: [Coordinate], distanceKm: Double, durationMin: Double, elevGainM: Double?,
        elevProfile: [Double]?, elevationIntervalM: Double?, updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.activity = activity
        self.waypoints = waypoints
        self.isLoop = isLoop
        self.coords = coords
        self.distanceKm = distanceKm
        self.durationMin = durationMin
        self.elevGainM = elevGainM
        self.elevProfile = elevProfile
        self.elevationIntervalM = elevationIntervalM
        self.updatedAt = updatedAt
    }
}

public struct TrackPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var horizontalAccuracy: Double
    public var timestamp: Date

    public init(latitude: Double, longitude: Double, altitude: Double?, horizontalAccuracy: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }

    public init(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

public enum SessionSource: String, Codable, Sendable {
    case phone, watch
}

/// A recorded workout. Created once on whichever device recorded it, never edited.
public struct SessionDTO: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var routeId: UUID?
    public var routeName: String?
    public var activity: ActivityKind
    public var start: Date
    public var end: Date
    public var trackPoints: [TrackPoint]
    public var distanceKm: Double
    public var avgHR: Double?
    public var activeEnergyKcal: Double?
    public var healthKitUUID: UUID?
    public var source: SessionSource

    public init(
        id: UUID = UUID(), routeId: UUID?, routeName: String?, activity: ActivityKind, start: Date, end: Date,
        trackPoints: [TrackPoint], distanceKm: Double, avgHR: Double?, activeEnergyKcal: Double?,
        healthKitUUID: UUID?, source: SessionSource
    ) {
        self.id = id
        self.routeId = routeId
        self.routeName = routeName
        self.activity = activity
        self.start = start
        self.end = end
        self.trackPoints = trackPoints
        self.distanceKm = distanceKm
        self.avgHR = avgHR
        self.activeEnergyKcal = activeEnergyKcal
        self.healthKitUUID = healthKitUUID
        self.source = source
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// JSON coding used for storage blobs and WatchConnectivity files.
public enum JSONCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
