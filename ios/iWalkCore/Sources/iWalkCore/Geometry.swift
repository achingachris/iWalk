import Foundation

public enum Geo {
    public static let earthRadiusM = 6_371_000.0

    /// Great-circle distance in metres.
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusM * asin(min(1, sqrt(h)))
    }

    public static func length(of coords: [Coordinate]) -> Double {
        guard coords.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<coords.count { total += distance(coords[i - 1], coords[i]) }
        return total
    }

    /// Drops points closer than `minSpacingM` to the last kept one (always keeps the last point),
    /// then thins evenly if still above `maxPoints`. Keeps request sizes sane for long walks.
    public static func thin(_ coords: [Coordinate], minSpacingM: Double = 10, maxPoints: Int = 4000) -> [Coordinate] {
        guard coords.count > 2 else { return coords }
        var kept = [coords[0]]
        for c in coords.dropFirst().dropLast() where distance(kept[kept.count - 1], c) >= minSpacingM {
            kept.append(c)
        }
        kept.append(coords[coords.count - 1])
        guard kept.count > maxPoints else { return kept }
        let step = Double(kept.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { kept[Int((Double($0) * step).rounded())] }
    }

    /// Waypoints for re-planning a path: the start, a point about every `everyM`, and the end,
    /// at most `maxCount` in total.
    public static func waypoints(along coords: [Coordinate], everyM: Double = 400, maxCount: Int = 20) -> [Coordinate] {
        guard let first = coords.first, let last = coords.last, coords.count > 1 else { return coords }
        let total = length(of: coords)
        let spacing = max(everyM, total / Double(max(1, maxCount - 1)))
        var result = [first]
        var sinceLast = 0.0
        for i in 1..<coords.count {
            sinceLast += distance(coords[i - 1], coords[i])
            if sinceLast >= spacing, i < coords.count - 1 {
                result.append(coords[i])
                sinceLast = 0
            }
        }
        result.append(last)
        return result
    }
}

/// Compares a recorded track with the planned route it followed.
public enum RouteComparison {
    public struct Result: Sendable, Equatable {
        /// Track length further than the threshold from the planned route, in metres.
        public var offRouteM: Double
        /// Total track length, in metres.
        public var trackM: Double

        /// True when the walk took a meaningfully different path: at least 250 m, or 15% of the
        /// walk, away from the route. Short GPS wobbles and brief detours don't count.
        public var differs: Bool {
            trackM >= 200 && (offRouteM >= 250 || offRouteM >= 0.15 * trackM)
        }
    }

    /// Runs on the device, no internet needed. A track segment counts as off-route when both of
    /// its ends are more than `thresholdM` from the planned route.
    public static func compare(track: [Coordinate], planned: RouteGeometry, thresholdM: Double = 40) -> Result {
        guard track.count > 1 else { return Result(offRouteM: 0, trackM: 0) }
        var off = 0.0, total = 0.0
        var prevOff = (planned.nearest(to: track[0])?.distanceM ?? 0) > thresholdM
        for i in 1..<track.count {
            let step = Geo.distance(track[i - 1], track[i])
            total += step
            let isOff = (planned.nearest(to: track[i])?.distanceM ?? 0) > thresholdM
            if isOff && prevOff { off += step }
            prevOff = isOff
        }
        return Result(offRouteM: off, trackM: total)
    }
}

/// Precomputed route geometry for fast "how far am I from the route, and how far along it" queries.
/// Uses a local equirectangular projection around the query point, accurate to well under a metre
/// at walking scales.
public struct RouteGeometry: Sendable {
    public let coords: [Coordinate]
    /// Cumulative distance in metres to each vertex.
    public let cumulative: [Double]

    public init(_ coords: [Coordinate]) {
        self.coords = coords
        var cum = [0.0]
        cum.reserveCapacity(coords.count)
        if coords.count > 1 {
            for i in 1..<coords.count { cum.append(cum[i - 1] + Geo.distance(coords[i - 1], coords[i])) }
        }
        self.cumulative = cum
    }

    public var totalLengthM: Double { cumulative.last ?? 0 }

    public struct Match: Sendable {
        /// Shortest distance from the point to the route, in metres.
        public let distanceM: Double
        /// Distance along the route to the closest point, in metres.
        public let alongM: Double
    }

    public func nearest(to p: Coordinate) -> Match? {
        guard let first = coords.first else { return nil }
        if coords.count == 1 {
            return Match(distanceM: Geo.distance(p, first), alongM: 0)
        }
        let mPerDegLat = Geo.earthRadiusM * .pi / 180
        let mPerDegLon = mPerDegLat * cos(p.latitude * .pi / 180)

        func project(_ c: Coordinate) -> (x: Double, y: Double) {
            ((c.longitude - p.longitude) * mPerDegLon, (c.latitude - p.latitude) * mPerDegLat)
        }

        var best = Double.greatestFiniteMagnitude
        var bestAlong = 0.0
        var a = project(coords[0])
        for i in 1..<coords.count {
            let b = project(coords[i])
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            // The query point is the origin, so t is the projection of -a onto the segment.
            let t = len2 > 0 ? max(0, min(1, -(a.x * dx + a.y * dy) / len2)) : 0
            let cx = a.x + t * dx, cy = a.y + t * dy
            let d = (cx * cx + cy * cy).squareRoot()
            if d < best {
                best = d
                bestAlong = cumulative[i - 1] + t * (cumulative[i] - cumulative[i - 1])
            }
            a = b
        }
        return Match(distanceM: best, alongM: bestAlong)
    }
}
