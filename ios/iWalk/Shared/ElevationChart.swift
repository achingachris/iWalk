import Charts
import SwiftUI

/// Elevation profile: metres against distance in km.
struct ElevationChart: View {
    let elevation: [Double]
    let intervalM: Double

    private var points: [(km: Double, m: Double)] {
        elevation.enumerated().map { (Double($0.offset) * intervalM / 1000, $0.element) }
    }

    var body: some View {
        let lo = (elevation.min() ?? 0) - 5
        let hi = (elevation.max() ?? 0) + 5
        Chart(points, id: \.km) { p in
            AreaMark(x: .value("km", p.km), yStart: .value("Base", lo), yEnd: .value("m", p.m))
                .foregroundStyle(.green.opacity(0.25))
            LineMark(x: .value("km", p.km), y: .value("m", p.m))
                .foregroundStyle(.green)
        }
        .chartYScale(domain: lo...hi)
        .chartXAxisLabel("km")
        .chartYAxisLabel("m")
    }
}
