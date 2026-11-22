import SwiftUI
import iWalkCore

struct RootView: View {
    @Environment(AppServices.self) private var services
    @Environment(TrackingSession.self) private var tracking
    @Environment(MirroredWorkout.self) private var mirror
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var services = services
        TabView(selection: $services.selectedTab) {
            Tab("Plan", systemImage: "map", value: AppServices.Tab.plan) {
                PlannerView()
            }
            Tab("Routes", systemImage: "list.bullet", value: AppServices.Tab.routes) {
                RoutesView()
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: AppServices.Tab.history) {
                HistoryView()
            }
            Tab("Sync", systemImage: "applewatch.radiowaves.left.and.right", value: AppServices.Tab.sync) {
                SyncDebugView()
            }
        }
        .fullScreenCover(isPresented: .constant(tracking.state != .idle || mirror.isActive)) {
            LiveWorkoutView()
        }
        .task { await services.requestHealthAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { mirror.startLiveActivityIfPossible() }
        }
    }
}
