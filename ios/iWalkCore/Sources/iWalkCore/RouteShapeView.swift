import SwiftUI

/// Draws a planned route (grey) and a recorded track (tint) on a plain background.
/// Used on the Watch (no tiles) and on the iPhone when map tiles are unavailable offline.
public struct RouteShapeView: View {
    public var planned: [Coordinate]
    public var track: [Coordinate]
    public var current: Coordinate?
    public var lineWidth: CGFloat

    public init(planned: [Coordinate], track: [Coordinate] = [], current: Coordinate? = nil, lineWidth: CGFloat = 4) {
        self.planned = planned
        self.track = track
        self.current = current
        self.lineWidth = lineWidth
    }

    public var body: some View {
        Canvas { context, size in
            let all = planned + track + (current.map { [$0] } ?? [])
            guard let projection = Projection(points: all, size: size, padding: lineWidth * 3) else { return }

            func path(_ coords: [Coordinate]) -> Path {
                var p = Path()
                for (i, c) in coords.enumerated() {
                    let pt = projection.point(c)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }

            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            if planned.count > 1 {
                context.stroke(path(planned), with: .color(.gray.opacity(0.6)), style: style)
            }
            if let start = planned.first {
                let pt = projection.point(start)
                context.fill(Path(ellipseIn: CGRect(x: pt.x - lineWidth * 1.5, y: pt.y - lineWidth * 1.5,
                                                    width: lineWidth * 3, height: lineWidth * 3)),
                             with: .color(.green))
            }
            if track.count > 1 {
                context.stroke(path(track), with: .color(.orange), style: style)
            }
            if let current {
                let pt = projection.point(current)
                let r = lineWidth * 2
                context.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                             with: .color(.blue))
                context.stroke(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                               with: .color(.white), lineWidth: 2)
            }
        }
        .accessibilityLabel("Route outline")
    }

    /// Equirectangular projection fitted to the view, preserving aspect ratio.
    struct Projection {
        let minX: Double, maxY: Double, scale: Double, offset: CGPoint, cosLat: Double

        init?(points: [Coordinate], size: CGSize, padding: CGFloat) {
            guard let first = points.first, size.width > 0, size.height > 0 else { return nil }
            let lats = points.map(\.latitude)
            let midLat = ((lats.min() ?? first.latitude) + (lats.max() ?? first.latitude)) / 2
            let k = cos(midLat * .pi / 180)
            cosLat = k
            let xs = points.map { $0.longitude * k }
            let ys = lats
            minX = xs.min()!
            let maxX = xs.max()!
            let minY = ys.min()!
            maxY = ys.max()!
            let w = max(maxX - minX, 1e-6), h = max(maxY - minY, 1e-6)
            let availW = Double(size.width - padding * 2), availH = Double(size.height - padding * 2)
            scale = min(availW / w, availH / h)
            offset = CGPoint(x: padding + (availW - w * scale) / 2, y: padding + (availH - h * scale) / 2)
        }

        func point(_ c: Coordinate) -> CGPoint {
            CGPoint(x: offset.x + (c.longitude * cosLat - minX) * scale,
                    y: offset.y + (maxY - c.latitude) * scale)
        }
    }
}
