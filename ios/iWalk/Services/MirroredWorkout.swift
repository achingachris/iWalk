import Foundation
import HealthKit
import UIKit
import iWalkCore

/// Receives a Watch workout mirrored to the iPhone (watchOS 10+ `startMirroringToCompanionDevice`).
/// The Watch records; the phone only displays. Live only: needs the phone in Bluetooth range.
/// Stats arrive as `MirrorUpdate`s over the session's data channel (iOS 17+), because the
/// mirrored workout builder on iPhone needs iOS 26.
@Observable
final class MirroredWorkout: NSObject {
    private(set) var isActive = false
    private(set) var isConnected = false
    private(set) var startedAt: Date?
    private(set) var activity: ActivityKind = .walk
    private(set) var latest: MirrorUpdate?
    private var latestReceivedAt: Date?

    private let health: HKHealthStore
    private let liveActivity: LiveActivityController
    private var session: HKWorkoutSession?

    init(health: HKHealthStore, liveActivity: LiveActivityController) {
        self.health = health
        self.liveActivity = liveActivity
        super.init()
    }

    /// Set at launch. iOS can launch the app in the background to deliver the session.
    func install() {
        health.workoutSessionMirroringStartHandler = { @Sendable [weak self] session in
            Task { @MainActor in self?.attach(session) }
        }
    }

    private func attach(_ session: HKWorkoutSession) {
        self.session = session
        session.delegate = self
        activity = ActivityKind(workoutActivityType: session.workoutConfiguration.activityType)
        startedAt = session.startDate ?? .now
        latest = nil
        latestReceivedAt = nil
        isActive = true
        isConnected = true
        startLiveActivityIfPossible()
    }

    /// Live Activities can only be started from the foreground; RootView calls this again on activation.
    func startLiveActivityIfPossible() {
        guard isActive, !liveActivity.isRunning, UIApplication.shared.applicationState == .active else { return }
        liveActivity.start(routeName: latest?.routeName ?? activity.title, activity: activity, state: contentState)
    }

    var isPaused: Bool { latest?.isPaused ?? false }
    var distanceKm: Double { latest?.distanceKm ?? 0 }
    var heartRate: Double? { latest?.heartRate }

    /// Elapsed time from the last update, advanced locally between updates while running.
    var elapsed: TimeInterval {
        guard let latest, let receivedAt = latestReceivedAt else {
            return startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        }
        return latest.elapsedS + (latest.isPaused ? 0 : Date.now.timeIntervalSince(receivedAt))
    }

    var paceSecPerKm: Double? {
        distanceKm > 0.02 ? elapsed / distanceKm : nil
    }

    var contentState: RouteActivityAttributes.ContentState {
        // The widget counts up from startedAt; shift it so paused time is not counted.
        .init(startedAt: Date.now.addingTimeInterval(-elapsed), distanceKm: distanceKm, paceSecPerKm: paceSecPerKm,
              remainingKm: latest?.remainingKm, heartRate: heartRate, offRoute: latest?.offRoute ?? false,
              fromWatch: true)
    }

    private func finish() {
        liveActivity.end(contentState)
        isActive = false
        isConnected = false
        session = nil
    }

    fileprivate func apply(_ update: MirrorUpdate) {
        let wasOff = latest?.offRoute ?? false
        let wasPaused = latest?.isPaused ?? false
        latest = update
        latestReceivedAt = .now
        isConnected = true
        if update.offRoute != wasOff {
            UINotificationFeedbackGenerator().notificationOccurred(update.offRoute ? .warning : .success)
        }
        startLiveActivityIfPossible()
        liveActivity.update(contentState, force: update.offRoute != wasOff || update.isPaused != wasPaused)
    }

    fileprivate func apply(state: HKWorkoutSessionState) {
        if state == .ended || state == .stopped { finish() }
    }

    fileprivate func setDisconnected() { isConnected = false }
}

extension MirroredWorkout: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in self.apply(state: toState) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("Mirrored session failed: \(error)")
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        let updates = data.compactMap { try? JSONCoding.decoder.decode(MirrorUpdate.self, from: $0) }
        guard let last = updates.max(by: { $0.sentAt < $1.sentAt }) else { return }
        Task { @MainActor in self.apply(last) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor in self.setDisconnected() }
    }
}
