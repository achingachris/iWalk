import Foundation
import SwiftData
import WatchConnectivity
import iWalkCore
import iWalkStore

/// Watch side of phone ↔ Watch sync (no internet needed).
/// - Receives the route list; applies it only if its version is newer, then acks the version.
/// - Sends each finished session from an outbox file, deleting it only after a successful transfer.
@Observable
final class WatchSync: NSObject {
    private(set) var activationState: WCSessionActivationState = .notActivated
    private(set) var isReachable = false
    private(set) var outstandingTransfers = 0
    private(set) var outboxCount = 0
    private(set) var lastRoutesAt: Date?
    private(set) var lastSessionSentAt: Date?
    private(set) var lastError: String?

    private(set) var appliedVersion: Int {
        didSet { UserDefaults.standard.set(appliedVersion, forKey: "appliedRouteVersion") }
    }

    private let context: ModelContext

    /// Called when the iPhone asks the Watch to start a route.
    var onStartRequest: ((WatchStartRequest) -> Void)?

    init(context: ModelContext) {
        self.context = context
        appliedVersion = UserDefaults.standard.integer(forKey: "appliedRouteVersion")
        super.init()
        refreshOutboxCount()
    }

    static var outboxURL: URL {
        let url = URL.documentsDirectory.appending(path: "outbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Writes the session to the outbox first, so it survives a force-quit before the transfer finishes.
    func send(_ session: SessionDTO) {
        do {
            let url = Self.outboxURL.appending(path: "\(session.id.uuidString).json")
            try JSONCoding.encoder.encode(session).write(to: url, options: .atomic)
            refreshOutboxCount()
            flushOutbox()
        } catch {
            lastError = "Could not queue the session: \(error.localizedDescription)"
        }
    }

    /// Queues every outbox file that is not already being transferred.
    func flushOutbox() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated else { return }
        let inFlight = Set(session.outstandingFileTransfers.compactMap { $0.file.metadata?[SyncKey.sessionId] as? String })
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.outboxURL, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard !inFlight.contains(id) else { continue }
            session.transferFile(file, metadata: [SyncKey.kind: SyncKey.Kind.session, SyncKey.sessionId: id])
        }
        refresh()
    }

    func refresh() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        activationState = s.activationState
        guard s.activationState == .activated else { return }
        isReachable = s.isReachable
        outstandingTransfers = s.outstandingFileTransfers.count
    }

    private func refreshOutboxCount() {
        outboxCount = ((try? FileManager.default.contentsOfDirectory(at: Self.outboxURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.count
    }

    fileprivate func received(routeBundle data: Data) {
        do {
            let bundle = try JSONCoding.decoder.decode(RouteBundle.self, from: data)
            if bundle.version > appliedVersion {
                try context.replaceRoutes(with: bundle.routes)
                appliedVersion = bundle.version
                lastRoutesAt = .now
            }
            // Ack what we have, even for an older bundle, so the phone stops resending.
            WCSession.default.transferUserInfo([SyncKey.ackRouteVersion: appliedVersion])
        } catch {
            lastError = "Could not apply routes: \(error.localizedDescription)"
        }
    }

    fileprivate func transferFinished(sessionId: String?, error: String?) {
        if let error {
            lastError = "Session transfer failed: \(error)"
        } else if let sessionId {
            try? FileManager.default.removeItem(at: Self.outboxURL.appending(path: "\(sessionId).json"))
            lastSessionSentAt = .now
        }
        refreshOutboxCount()
        refresh()
    }
}

extension WatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.refresh()
            self.flushOutbox()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The file is deleted when this method returns, so read it synchronously here.
        guard file.metadata?[SyncKey.kind] as? String == SyncKey.Kind.routeBundle,
              let data = try? Data(contentsOf: file.fileURL) else { return }
        Task { @MainActor in self.received(routeBundle: data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let request = WatchStartRequest(userInfo: message) else { return }
        Task { @MainActor in self.onStartRequest?(request) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let request = WatchStartRequest(userInfo: userInfo) else { return }
        Task { @MainActor in self.onStartRequest?(request) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let id = fileTransfer.file.metadata?[SyncKey.sessionId] as? String
        let message = error?.localizedDescription
        Task { @MainActor in self.transferFinished(sessionId: id, error: message) }
    }
}
