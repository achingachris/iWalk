import ActivityKit
import SwiftUI
import WidgetKit
import iWalkCore

@main
struct iWalkWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RouteLiveActivity()
    }
}

/// Lock screen and Dynamic Island for a walk in progress. Drawn entirely from ContentState,
/// which the app updates locally every ~7 s; no network or push involved.
struct RouteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RouteActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.7))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.activity.title, systemImage: context.attributes.activity.systemImage)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(start: context.state.startedAt)
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.routeName).font(.caption).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StatsRow(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.offRoute ? "exclamationmark.triangle.fill"
                                                         : context.attributes.activity.systemImage)
                    .foregroundStyle(context.state.offRoute ? .red : .green)
            } compactTrailing: {
                Text(Format.distance(km: context.state.distanceKm))
                    .font(.caption.monospacedDigit())
            } minimal: {
                Image(systemName: context.attributes.activity.systemImage)
                    .foregroundStyle(context.state.offRoute ? .red : .green)
            }
        }
    }
}

private struct LockScreenView: View {
    let attributes: RouteActivityAttributes
    let state: RouteActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(attributes.routeName, systemImage: attributes.activity.systemImage)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if state.fromWatch {
                    Image(systemName: "applewatch").foregroundStyle(.secondary)
                }
                ElapsedText(start: state.startedAt)
                    .font(.title3.monospacedDigit().bold())
            }
            if state.offRoute {
                Label("Off route", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.red)
            }
            StatsRow(state: state)
        }
        .foregroundStyle(.white)
    }
}

private struct StatsRow: View {
    let state: RouteActivityAttributes.ContentState

    var body: some View {
        HStack {
            Item(title: "Distance", value: Format.distance(km: state.distanceKm))
            Item(title: "Pace", value: Format.pace(secondsPerKm: state.paceSecPerKm))
            if let hr = state.heartRate {
                Item(title: "HR", value: "\(Int(hr))")
            } else {
                Item(title: "Left", value: state.remainingKm.map { Format.distance(km: $0) } ?? "—")
            }
        }
    }

    private struct Item: View {
        let title: String
        let value: String

        var body: some View {
            VStack(spacing: 2) {
                Text(value).font(.subheadline.monospacedDigit().bold())
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Counts up on its own between updates, so the clock stays live with no app work.
private struct ElapsedText: View {
    let start: Date

    var body: some View {
        Text(timerInterval: start...Date.distantFuture, countsDown: false)
            .multilineTextAlignment(.trailing)
    }
}
