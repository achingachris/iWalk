import SwiftData
import SwiftUI
import iWalkCore
import iWalkStore

@main
struct iWalkWatchApp: App {
    @State private var services = WatchServices()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(services.workout)
                .environment(services.sync)
        }
        .modelContainer(services.container)
    }
}

@Observable
final class WatchServices {
    let container: ModelContainer
    let sync: WatchSync
    let workout: WorkoutManager

    init() {
        container = iWalkSchema.makeContainer()
        sync = WatchSync(context: container.mainContext)
        workout = WorkoutManager()
        workout.onFinished = { [sync] session in sync.send(session) }
        sync.activate()
    }
}
