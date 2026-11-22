import HealthKit
import SwiftData
import SwiftUI
import WatchKit
import iWalkCore
import iWalkStore

@main
struct iWalkWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
    @State private var services = WatchServices.shared

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(services.workout)
                .environment(services.sync)
        }
        .modelContainer(services.container)
    }
}

/// Receives the workout configuration when the iPhone calls `HKHealthStore.startWatchApp`
/// ("Start on Apple Watch"). The Watch then records the workout, so it lands in Fitness.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { await WatchServices.shared.workout.startFromPhone(workoutConfiguration) }
    }
}

@Observable
final class WatchServices {
    /// Shared so the app delegate can reach the workout manager.
    static let shared = WatchServices()

    let container: ModelContainer
    let sync: WatchSync
    let workout: WorkoutManager

    private init() {
        container = iWalkSchema.makeContainer()
        sync = WatchSync(context: container.mainContext)
        workout = WorkoutManager()
        let context = container.mainContext
        workout.routeLookup = { id in
            try? context.fetch(FetchDescriptor<RouteRecord>(predicate: #Predicate { $0.id == id })).first?.dto
        }
        workout.onFinished = { [sync] session in sync.send(session) }
        sync.onStartRequest = { [workout] request in workout.receive(request) }
        sync.activate()
    }
}
