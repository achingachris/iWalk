import SwiftData
import SwiftUI
import iWalkCore
import iWalkStore

struct RootView: View {
    @Environment(AppServices.self) private var services
    @Environment(TrackingSession.self) private var tracking
    @Environment(MirroredWorkout.self) private var mirror
    @Environment(NetworkMonitor.self) private var network
    @Environment(RouteReviewer.self) private var reviewer
    @Environment(\.scenePhase) private var scenePhase

    /// Finished walks not yet compared with their route (or saved as a new route).
    @Query(filter: #Predicate<SessionRecord> { $0.routeReviewRaw == nil })
    private var unreviewed: [SessionRecord]
    @Query(filter: #Predicate<SessionRecord> { $0.routeReviewRaw == "pending" })
    private var pendingReviews: [SessionRecord]

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
            .badge(pendingReviews.count)
            Tab("Sync", systemImage: "applewatch.radiowaves.left.and.right", value: AppServices.Tab.sync) {
                SyncDebugView()
            }
        }
        .fullScreenCover(isPresented: .constant(tracking.state != .idle || mirror.isActive)) {
            LiveWorkoutView()
        }
        .task { await services.requestHealthAuthorization() }
        // Check walks against their routes on launch, when a new walk arrives, and when back online.
        .task(id: ReviewTrigger(unreviewed: unreviewed.count, online: network.isOnline)) {
            await reviewer.reviewPending()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { mirror.startLiveActivityIfPossible() }
        }
    }

    private struct ReviewTrigger: Equatable {
        let unreviewed: Int
        let online: Bool
    }
}
