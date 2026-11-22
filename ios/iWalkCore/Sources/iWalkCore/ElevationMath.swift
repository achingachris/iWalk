import Foundation

public enum ElevationMath {
    /// Centred moving average. Windows shrink at the ends so the output has the same length.
    public static func smooth(_ values: [Double], window: Int = 5) -> [Double] {
        guard window > 1, values.count > 2 else { return values }
        let half = window / 2
        return values.indices.map { i in
            let lo = max(0, i - half)
            let hi = min(values.count - 1, i + half)
            let slice = values[lo...hi]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    /// Total climb in metres. Smooths first, then counts only rises of at least `threshold`
    /// metres above the lowest point since the last counted rise, so GPS/DEM noise is ignored.
    public static func gain(_ values: [Double], window: Int = 5, threshold: Double = 3) -> Double {
        let s = smooth(values, window: window)
        guard var anchor = s.first else { return 0 }
        var total = 0.0
        for v in s.dropFirst() {
            if v - anchor >= threshold {
                total += v - anchor
                anchor = v
            } else if v < anchor {
                anchor = v
            }
        }
        return total
    }
}
