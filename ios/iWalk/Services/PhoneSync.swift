import Foundation
import SwiftData
import WatchConnectivity
import iWalkCore
import iWalkStore

/// Phone side of phone ↔ Watch sync over WatchConnectivity (Bluetooth / local Wi-Fi, no internet).
/// - Routes, phone → Watch: the whole list as one JSON file with a version number.
/// - Sessions, Watch → phone: one JSON file per session, upserted by id.
@Observable
final class PhoneSync: NSObject {
    private(set) var activationState: WCSessionActivationState = .notActivated
    private(set) var isPaired = false
    private(set) var isWatchAppInstalled = false
    private(set) var isReachable = false
    private(set) var outstandingTransfers = 0
    private(set) var lastSentAt: Date?
    private(set) var lastReceivedAt: Date?
    private(set) var lastError: String?

    private(set) var routesVersion: Int {
        didSet { UserDefaults.standard.set(routesVersion, forKey: "routesVersion") }
    }
    private(set) var ackedVersion: Int {
        didSet { UserDefaults.standard.set(ackedVersion, forKey: "ackedRouteVersion") }
    }

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        routesVersion = UserDefaults.standard.integer(forKey: "routesVersion")
        ackedVersion = UserDefaults.standard.integer(forKey: "ackedRouteVersion")
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Call after every route create / edit / rename / delete.
    func routesChanged() {
        routesVersion += 1
        sendRoutes()
    }

    func sendRoutes() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        do {
            let bundle = RouteBundle(version: routesVersion, routes: try context.allRouteDTOs())
            let data = try JSONCoding.encoder.encode(bundle)
            let url = FileManager.default.temporaryDirectory.appending(path: "routes-v\(routesVersion).json")
            try data.write(to: url, options: .atomic)

            // Only the newest list matters: drop queued older ones so a burst of edits
            // while the Watch is away delivers just the latest version.
            for transfer in session.outstandingFileTransfers
            where transfer.file.metadata?[SyncKey.kind] as? String == SyncKey.Kind.routeBundle {
                transfer.cancel()
            }
            session.transferFile(url, metadata: [SyncKey.kind: SyncKey.Kind.routeBundle,
                                                 SyncKey.version: routesVersion])
            lastSentAt = .now
            refresh()
        } catch {
            lastError = "Could not send routes: \(error.localizedDescription)"
        }
    }

    func refresh() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        activationState = s.activationState
        guard s.activationState == .activated else { return }
        isPaired = s.isPaired
        isWatchAppInstalled = s.isWatchAppInstalled
        isReachable = s.isReachable
        outstandingTransfers = s.outstandingFileTransfers.count
    }

    private func resendIfNeeded() {
        refresh()
        if ackedVersion < routesVersion {
            let alreadyQueued = WCSession.default.outstandingFileTransfers.contains {
                $0.file.metadata?[SyncKey.version] as? Int == routesVersion
            }
            if !alreadyQueued { sendRoutes() }
        }
    }

    fileprivate func received(sessionData data: Data) {
        do {
            let dto = try JSONCoding.decoder.decode(SessionDTO.self, from: data)
            try context.upsertSession(dto)
            lastReceivedAt = .now
        } catch {
            lastError = "Could not store a Watch session: \(error.localizedDescription)"
        }
    }

    fileprivate func received(ack version: Int) {
        ackedVersion = max(ackedVersion, version)
        refresh()
    }
}

extension PhoneSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.resendIfNeeded() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switching to another Watch: reactivate for the new one.
        WCSession.default.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.resendIfNeeded() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The file is deleted when this method returns, so read it synchronously here.
        guard file.metadata?[SyncKey.kind] as? String == SyncKey.Kind.session,
              let data = try? Data(contentsOf: file.fileURL) else { return }
        Task { @MainActor in self.received(sessionData: data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let version = userInfo[SyncKey.ackRouteVersion] as? Int else { return }
        Task { @MainActor in self.received(ack: version) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        let message = error.map { "Transfer failed: \($0.localizedDescription)" }
        try? FileManager.default.removeItem(at: url)
        Task { @MainActor in
            if let message { self.lastError = message }
            self.refresh()
        }
    }
}
