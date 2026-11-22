import SwiftUI
import WatchConnectivity

struct SyncDebugView: View {
    @Environment(PhoneSync.self) private var sync

    var body: some View {
        NavigationStack {
            List {
                Section("Watch") {
                    LabeledContent("Activation", value: sync.activationState.label)
                    LabeledContent("Paired", value: sync.isPaired ? "Yes" : "No")
                    LabeledContent("Watch app installed", value: sync.isWatchAppInstalled ? "Yes" : "No")
                    LabeledContent("Reachable now", value: sync.isReachable ? "Yes" : "No")
                }
                Section("Routes") {
                    LabeledContent("Phone version", value: "\(sync.routesVersion)")
                    LabeledContent("Watch confirmed", value: "\(sync.ackedVersion)")
                    LabeledContent("Outstanding transfers", value: "\(sync.outstandingTransfers)")
                    LabeledContent("Last sent", value: sync.lastSentAt?.formatted(date: .omitted, time: .standard) ?? "—")
                    LabeledContent("Last session received",
                                   value: sync.lastReceivedAt?.formatted(date: .omitted, time: .standard) ?? "—")
                    Button("Resend routes now", systemImage: "arrow.clockwise") { sync.sendRoutes() }
                }
                if let error = sync.lastError {
                    Section("Last error") { Text(error).foregroundStyle(.red) }
                }
                Section("Routing server") {
                    LabeledContent("Planner", value: AppConfig.usesValhalla ? "Valhalla" : "Apple walking (no server set)")
                    if let url = AppConfig.baseURL { LabeledContent("URL", value: url.host() ?? url.absoluteString) }
                }
            }
            .navigationTitle("Sync")
            .refreshable { sync.refresh() }
            .onAppear { sync.refresh() }
        }
    }
}

extension WCSessionActivationState {
    var label: String {
        switch self {
        case .activated: "Activated"
        case .inactive: "Inactive"
        case .notActivated: "Not activated"
        @unknown default: "Unknown"
        }
    }
}
