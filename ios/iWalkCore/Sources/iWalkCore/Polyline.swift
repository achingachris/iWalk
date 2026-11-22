import Foundation

/// Decoder for Google-style encoded polylines. Valhalla's `shape` uses 6 digits (polyline6).
public enum Polyline {
    public static func decode(_ encoded: String, precision: Double = 1e6) -> [Coordinate] {
        let bytes = Array(encoded.utf8)
        var index = 0
        var lat = 0
        var lon = 0
        var result: [Coordinate] = []
        result.reserveCapacity(bytes.count / 4)

        func nextValue() -> Int? {
            var shift = 0
            var value = 0
            while index < bytes.count {
                let byte = Int(bytes[index]) - 63
                index += 1
                value |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 {
                    return (value & 1) != 0 ? ~(value >> 1) : (value >> 1)
                }
            }
            return nil
        }

        while index < bytes.count {
            guard let dLat = nextValue(), let dLon = nextValue() else { break }
            lat += dLat
            lon += dLon
            result.append(Coordinate(latitude: Double(lat) / precision, longitude: Double(lon) / precision))
        }
        return result
    }
}
