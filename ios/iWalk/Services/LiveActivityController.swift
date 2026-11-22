import ActivityKit
import Foundation
import iWalkCore

/// Starts, updates and ends the lock-screen / Dynamic Island Live Activity.
/// Updated locally (no push), throttled to about every 7 seconds to save battery.
@Observable
final class LiveActivityController {
    private var activity: Activity<RouteActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private let minInterval: TimeInterval = 7

    var isRunning: Bool { activity != nil }

    /// Must be called while the app is on screen.
    func start(routeName: String, activity kind: ActivityKind, state: RouteActivityAttributes.ContentState) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: RouteActivityAttributes(routeName: routeName, activity: kind),
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            lastUpdate = .now
        } catch {
            print("Live Activity request failed: \(error)")
        }
    }

    func update(_ state: RouteActivityAttributes.ContentState, force: Bool = false) {
        guard let activity else { return }
        let now = Date.now
        guard force || now.timeIntervalSince(lastUpdate) >= minInterval else { return }
        lastUpdate = now
        // Activity is not Sendable in the SDK; it is only touched from here and end().
        nonisolated(unsafe) let target = activity
        Task {
            await target.update(.init(state: state, staleDate: now.addingTimeInterval(120)))
        }
    }

    func end(_ state: RouteActivityAttributes.ContentState?) {
        guard let activity else { return }
        self.activity = nil
        nonisolated(unsafe) let target = activity
        Task {
            let content = state.map { ActivityContent(state: $0, staleDate: nil) }
            await target.end(content, dismissalPolicy: .after(.now.addingTimeInterval(15 * 60)))
        }
    }
}
