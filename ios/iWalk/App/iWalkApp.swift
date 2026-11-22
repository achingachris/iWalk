import SwiftUI
import SwiftData
import HealthKit
import iWalkCore
import iWalkStore

@main
struct iWalkApp: App {
    // Created at launch so the HealthKit mirroring handler is installed before iOS
    // delivers a mirrored Watch workout (iOS may launch the app in the background for it).
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services)
                .environment(services.planner)
                .environment(services.tracking)
                .environment(services.mirror)
                .environment(services.sync)
                .environment(services.network)
                .environment(services.reviewer)
        }
        .modelContainer(services.container)
    }
}

/// Long-lived app services, shared through the environment.
@Observable
final class AppServices {
    enum Tab: Hashable { case plan, routes, history, sync }

    let container: ModelContainer
    let health = HKHealthStore()
    let network = NetworkMonitor()
    let liveActivity = LiveActivityController()
    let planner = PlannerModel()
    let sync: PhoneSync
    let mirror: MirroredWorkout
    let tracking: TrackingSession
    let reviewer: RouteReviewer

    var selectedTab: Tab = .plan

    init() {
        container = iWalkSchema.makeContainer()
        sync = PhoneSync(context: container.mainContext)
        reviewer = RouteReviewer(context: container.mainContext, sync: sync, network: network)
        mirror = MirroredWorkout(health: health, liveActivity: liveActivity)
        tracking = TrackingSession(health: health, context: container.mainContext, liveActivity: liveActivity)
        tracking.mirror = mirror
        mirror.install()
        sync.activate()
    }

    /// Launches the Watch app into a workout ("Start on Apple Watch"), optionally following a route.
    /// The Watch records it (so it lands in Fitness with heart rate) and mirrors it back; the phone
    /// does not record ("one recorder"). Returns nil once the Watch is live, or a message for the user.
    func startOnWatch(activity: ActivityKind, route: RouteDTO?) async -> String? {
        sync.requestWatchStart(WatchStartRequest(routeId: route?.id, activity: activity))
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                health.startWatchApp(with: activity.workoutConfiguration) { success, error in
                    if success { continuation.resume() } else {
                        continuation.resume(throwing: error ?? CocoaError(.featureUnsupported))
                    }
                }
            }
        } catch {
            return "Couldn't start on the Watch: \(error.localizedDescription). Start on iPhone instead?"
        }
        // The mirrored session normally arrives within a few seconds.
        for _ in 0..<20 {
            if mirror.isActive { return nil }
            try? await Task.sleep(for: .seconds(1))
        }
        return "No live view from the Watch yet. If it's recording, the walk syncs here when it ends. If not, check the Watch is on your wrist and unlocked, or start on iPhone."
    }

    func requestHealthAuthorization() async {
        do {
            try await HealthTypes.requestAuthorization(health)
        } catch {
            print("HealthKit authorization failed: \(error)")
        }
    }
}

enum AppConfig {
    static var baseURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "IWalkBaseURL") as? String,
              !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return URL(string: s)
    }

    static var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "IWalkAPIKey") as? String ?? ""
    }

    static var usesValhalla: Bool { baseURL != nil }

    static func makePlanner() -> any RoutePlanner {
        if let baseURL {
            return FallbackPlanner(primary: ValhallaClient(baseURL: baseURL, apiKey: apiKey),
                                   fallback: AppleWalkingPlanner())
        }
        return AppleWalkingPlanner()
    }

    static func makeValhalla() -> ValhallaClient? {
        baseURL.map { ValhallaClient(baseURL: $0, apiKey: apiKey) }
    }

    static let mombasa = Coordinate(latitude: -4.05, longitude: 39.67)
}
