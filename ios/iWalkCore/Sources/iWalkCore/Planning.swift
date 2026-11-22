import Foundation
#if os(iOS)
import MapKit
#endif

/// Result of planning a route online. Saved into a `RouteDTO`, so everything needed
/// offline (geometry, elevation) is kept with the route.
public struct PlannedRoute: Sendable, Hashable {
    public var coords: [Coordinate]
    public var distanceKm: Double
    public var durationMin: Double
    /// Elevation samples in metres; nil when the planner cannot provide them (Apple fallback).
    public var elevation: [Double]?
    public var elevationIntervalM: Double?
    public var source: Source

    public enum Source: String, Sendable { case valhalla, apple }

    public var elevGainM: Double? { elevation.map { ElevationMath.gain($0) } }

    public init(coords: [Coordinate], distanceKm: Double, durationMin: Double, elevation: [Double]?,
                elevationIntervalM: Double?, source: Source) {
        self.coords = coords
        self.distanceKm = distanceKm
        self.durationMin = durationMin
        self.elevation = elevation
        self.elevationIntervalM = elevationIntervalM
        self.source = source
    }
}

public protocol RoutePlanner: Sendable {
    func plan(waypoints: [Coordinate], activity: ActivityKind) async throws -> PlannedRoute
}

public enum PlanningError: LocalizedError {
    case notEnoughWaypoints
    case server(status: Int, message: String)
    case badResponse
    case noRoute
    case appleUnavailable

    public var errorDescription: String? {
        switch self {
        case .notEnoughWaypoints: "Add at least two points."
        case .server(let status, let message): "Routing server error \(status): \(message)"
        case .badResponse: "The routing server sent a response iWalk could not read."
        case .noRoute: "No route found between these points."
        case .appleUnavailable: "Apple has no walking directions here. Planning needs the iWalk routing server."
        }
    }
}

// MARK: - Valhalla

/// Client for a Valhalla server behind Caddy. Sends the shared `X-iWalk-Key` header.
public struct ValhallaClient: RoutePlanner {
    public let baseURL: URL
    public let apiKey: String
    public let elevationIntervalM: Double
    let session: URLSession

    public init(baseURL: URL, apiKey: String, elevationIntervalM: Double = 30, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.elevationIntervalM = elevationIntervalM
        self.session = session
    }

    public func plan(waypoints: [Coordinate], activity: ActivityKind) async throws -> PlannedRoute {
        guard waypoints.count >= 2 else { throw PlanningError.notEnoughWaypoints }
        let body = RouteRequest(
            locations: waypoints.map { .init(lat: $0.latitude, lon: $0.longitude, type: "break") },
            costing: "pedestrian",
            costing_options: ["pedestrian": activity.pedestrianCostingOptions],
            units: "kilometers",
            elevation_interval: elevationIntervalM,
            directions_type: "none"
        )
        let response: RouteResponse = try await post("route", body: body)
        return Self.join(response.trip, elevationIntervalM: elevationIntervalM)
    }

    /// Snap a recorded track to OSM paths (`/trace_route`), with distance, time and elevation,
    /// so it can replace or become a saved route. Online only.
    public func snap(track: [Coordinate], activity: ActivityKind) async throws -> PlannedRoute {
        let shape = Geo.thin(track)
        guard shape.count >= 2 else { throw PlanningError.notEnoughWaypoints }
        let body = TraceRequest(
            shape: shape.map { .init(lat: $0.latitude, lon: $0.longitude, type: nil) },
            costing: "pedestrian",
            costing_options: ["pedestrian": activity.pedestrianCostingOptions],
            shape_match: "map_snap",
            // Phone GPS in narrow streets can sit 20-50 m off the mapped path.
            trace_options: .init(search_radius: 100, gps_accuracy: 20),
            units: "kilometers",
            elevation_interval: elevationIntervalM,
            directions_type: "none"
        )
        let response: RouteResponse = try await post("trace_route", body: body)
        let snapped = Self.join(response.trip, elevationIntervalM: elevationIntervalM)

        // If matching went wrong (paths missing from OSM, a noisy track), the snapped length is
        // far from what was walked. Then keep the recorded path itself rather than a bad match.
        let walkedKm = Geo.length(of: shape) / 1000
        guard walkedKm > 0.1, !(0.6...1.6).contains(snapped.distanceKm / walkedKm) else { return snapped }
        let heights = try? await heights(along: shape)
        return PlannedRoute(
            coords: shape, distanceKm: walkedKm, durationMin: walkedKm / activity.nominalSpeedKmh * 60,
            elevation: heights, elevationIntervalM: heights == nil ? nil : elevationIntervalM, source: .valhalla
        )
    }

    /// Elevation in metres every `elevationIntervalM` along a path (`/height`).
    public func heights(along coords: [Coordinate]) async throws -> [Double] {
        let body = HeightRequest(shape: coords.map { .init(lat: $0.latitude, lon: $0.longitude, type: nil) },
                                 resample_distance: elevationIntervalM)
        let response: HeightResponse = try await post("height", body: body)
        // Gaps in the elevation data come back as null; carry the previous value over them.
        var last = response.height.compactMap { $0 }.first ?? 0
        return response.height.map { h in
            if let h { last = h }
            return last
        }
    }

    static func join(_ trip: RouteResponse.Trip, elevationIntervalM: Double?) -> PlannedRoute {
        var coords: [Coordinate] = []
        var elevation: [Double] = []
        var hasElevation = false
        for leg in trip.legs {
            var shape = Polyline.decode(leg.shape)
            if let last = coords.last, let first = shape.first, Geo.distance(last, first) < 0.5 {
                shape.removeFirst()
            }
            coords.append(contentsOf: shape)
            if var e = leg.elevation, !e.isEmpty {
                hasElevation = true
                if !elevation.isEmpty { e.removeFirst() }
                elevation.append(contentsOf: e)
            }
        }
        return PlannedRoute(
            coords: coords,
            distanceKm: trip.summary.length,
            durationMin: trip.summary.time / 60,
            elevation: hasElevation ? elevation : nil,
            elevationIntervalM: hasElevation ? elevationIntervalM : nil,
            source: .valhalla
        )
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-iWalk-Key")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, urlResponse) = try await session.data(for: request)
        guard let http = urlResponse as? HTTPURLResponse else { throw PlanningError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
                ?? String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 400, message.localizedCaseInsensitiveContains("no path") {
                throw PlanningError.noRoute
            }
            throw PlanningError.server(status: http.statusCode, message: message)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw PlanningError.badResponse
        }
    }

    // Wire types. Field names follow the Valhalla API reference; check them against
    // docs/sample-route.json once the VPS is up.
    struct Location: Encodable {
        let lat: Double
        let lon: Double
        let type: String?
    }

    struct RouteRequest: Encodable {
        let locations: [Location]
        let costing: String
        let costing_options: [String: [String: Double]]
        let units: String
        let elevation_interval: Double
        let directions_type: String
    }

    struct TraceRequest: Encodable {
        let shape: [Location]
        let costing: String
        let costing_options: [String: [String: Double]]
        let shape_match: String
        let trace_options: TraceOptions
        let units: String
        let elevation_interval: Double
        let directions_type: String
    }

    struct TraceOptions: Encodable {
        let search_radius: Double
        let gps_accuracy: Double
    }

    struct HeightRequest: Encodable {
        let shape: [Location]
        let resample_distance: Double
    }

    struct HeightResponse: Decodable {
        let height: [Double?]
    }

    struct RouteResponse: Decodable {
        struct Summary: Decodable {
            /// Kilometres (we always send `units: kilometers`).
            let length: Double
            /// Seconds.
            let time: Double
        }
        struct Leg: Decodable {
            let shape: String
            let elevation: [Double]?
            let summary: Summary
        }
        struct Trip: Decodable {
            let legs: [Leg]
            let summary: Summary
        }
        let trip: Trip
    }

    struct ErrorResponse: Decodable {
        let error: String?
        let error_code: Int?
    }
}

// MARK: - Apple fallback

#if os(iOS)
/// Fallback when the Valhalla server is not configured or unreachable: Apple walking directions.
/// Street-only, no trail costing and no elevation.
public struct AppleWalkingPlanner: RoutePlanner {
    public init() {}

    public func plan(waypoints: [Coordinate], activity: ActivityKind) async throws -> PlannedRoute {
        guard waypoints.count >= 2 else { throw PlanningError.notEnoughWaypoints }
        var coords: [Coordinate] = []
        var meters = 0.0
        var seconds = 0.0
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: a.clCoordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b.clCoordinate))
            request.transportType = .walking
            let response: MKDirections.Response
            do {
                response = try await MKDirections(request: request).calculate()
            } catch let error as MKError where error.code == .directionsNotFound || error.code == .serverFailure {
                // Apple has no walking directions in much of Kenya, including Mombasa.
                throw PlanningError.appleUnavailable
            }
            guard let route = response.routes.first else { throw PlanningError.noRoute }
            var shape = route.polyline.coordinates.map(Coordinate.init)
            if !coords.isEmpty, !shape.isEmpty { shape.removeFirst() }
            coords.append(contentsOf: shape)
            meters += route.distance
            seconds += route.expectedTravelTime
        }
        // Apple assumes walking pace; rescale for runs and hikes.
        let scaledSeconds = seconds * ActivityKind.walk.nominalSpeedKmh / activity.nominalSpeedKmh
        return PlannedRoute(coords: coords, distanceKm: meters / 1000, durationMin: scaledSeconds / 60,
                            elevation: nil, elevationIntervalM: nil, source: .apple)
    }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var result = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&result, range: NSRange(location: 0, length: pointCount))
        return result
    }
}
#endif

/// Uses the primary planner and falls back to the secondary on network errors
/// (VPS down, no route to host). Server errors such as "no path" are passed through.
public struct FallbackPlanner: RoutePlanner {
    public let primary: any RoutePlanner
    public let fallback: any RoutePlanner

    public init(primary: any RoutePlanner, fallback: any RoutePlanner) {
        self.primary = primary
        self.fallback = fallback
    }

    public func plan(waypoints: [Coordinate], activity: ActivityKind) async throws -> PlannedRoute {
        do {
            return try await primary.plan(waypoints: waypoints, activity: activity)
        } catch is URLError {
            return try await fallback.plan(waypoints: waypoints, activity: activity)
        } catch PlanningError.server(let status, _) where status >= 500 {
            return try await fallback.plan(waypoints: waypoints, activity: activity)
        }
    }
}
