import Foundation
import SwiftData
import iWalkCore

/// SwiftData record for a planned route. Coordinate arrays are stored as JSON blobs.
@Model
public final class RouteRecord {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var activityRaw: String
    public var isLoop: Bool
    public var distanceKm: Double
    public var durationMin: Double
    public var elevGainM: Double?
    public var elevationIntervalM: Double?
    public var updatedAt: Date
    @Attribute(.externalStorage) public var waypointsData: Data
    @Attribute(.externalStorage) public var coordsData: Data
    public var elevProfileData: Data?

    public init(_ dto: RouteDTO) {
        id = dto.id
        name = dto.name
        activityRaw = dto.activity.rawValue
        isLoop = dto.isLoop
        distanceKm = dto.distanceKm
        durationMin = dto.durationMin
        elevGainM = dto.elevGainM
        elevationIntervalM = dto.elevationIntervalM
        updatedAt = dto.updatedAt
        waypointsData = (try? JSONCoding.encoder.encode(dto.waypoints)) ?? Data()
        coordsData = (try? JSONCoding.encoder.encode(dto.coords)) ?? Data()
        elevProfileData = dto.elevProfile.flatMap { try? JSONCoding.encoder.encode($0) }
    }

    public func update(from dto: RouteDTO) {
        name = dto.name
        activityRaw = dto.activity.rawValue
        isLoop = dto.isLoop
        distanceKm = dto.distanceKm
        durationMin = dto.durationMin
        elevGainM = dto.elevGainM
        elevationIntervalM = dto.elevationIntervalM
        updatedAt = dto.updatedAt
        waypointsData = (try? JSONCoding.encoder.encode(dto.waypoints)) ?? Data()
        coordsData = (try? JSONCoding.encoder.encode(dto.coords)) ?? Data()
        elevProfileData = dto.elevProfile.flatMap { try? JSONCoding.encoder.encode($0) }
    }

    public var activity: ActivityKind { ActivityKind(rawValue: activityRaw) ?? .walk }

    public var coords: [Coordinate] {
        (try? JSONCoding.decoder.decode([Coordinate].self, from: coordsData)) ?? []
    }

    public var dto: RouteDTO {
        RouteDTO(
            id: id, name: name, activity: activity,
            waypoints: (try? JSONCoding.decoder.decode([Coordinate].self, from: waypointsData)) ?? [],
            isLoop: isLoop, coords: coords, distanceKm: distanceKm, durationMin: durationMin,
            elevGainM: elevGainM,
            elevProfile: elevProfileData.flatMap { try? JSONCoding.decoder.decode([Double].self, from: $0) },
            elevationIntervalM: elevationIntervalM, updatedAt: updatedAt
        )
    }
}

/// SwiftData record for a recorded session. Created once, never edited.
@Model
public final class SessionRecord {
    @Attribute(.unique) public var id: UUID
    public var routeId: UUID?
    public var routeName: String?
    public var activityRaw: String
    public var start: Date
    public var end: Date
    public var distanceKm: Double
    public var avgHR: Double?
    public var activeEnergyKcal: Double?
    public var healthKitUUID: UUID?
    public var sourceRaw: String
    @Attribute(.externalStorage) public var trackData: Data

    public init(_ dto: SessionDTO) {
        id = dto.id
        routeId = dto.routeId
        routeName = dto.routeName
        activityRaw = dto.activity.rawValue
        start = dto.start
        end = dto.end
        distanceKm = dto.distanceKm
        avgHR = dto.avgHR
        activeEnergyKcal = dto.activeEnergyKcal
        healthKitUUID = dto.healthKitUUID
        sourceRaw = dto.source.rawValue
        trackData = (try? JSONCoding.encoder.encode(dto.trackPoints)) ?? Data()
    }

    public var activity: ActivityKind { ActivityKind(rawValue: activityRaw) ?? .walk }
    public var source: SessionSource { SessionSource(rawValue: sourceRaw) ?? .phone }

    public var trackPoints: [TrackPoint] {
        (try? JSONCoding.decoder.decode([TrackPoint].self, from: trackData)) ?? []
    }
}

public enum iWalkSchema {
    public static let models: [any PersistentModel.Type] = [RouteRecord.self, SessionRecord.self]

    @MainActor
    public static func makeContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: Schema(models))
        } catch {
            fatalError("Could not open the iWalk store: \(error)")
        }
    }
}

extension ModelContext {
    /// Insert or ignore by `id`, so a session delivered twice over WatchConnectivity is stored once.
    @discardableResult
    public func upsertSession(_ dto: SessionDTO) throws -> Bool {
        let id = dto.id
        let existing = try fetchCount(FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id }))
        guard existing == 0 else { return false }
        insert(SessionRecord(dto))
        try save()
        return true
    }

    /// Replace the whole route store with `routes` (used by the Watch when a newer bundle arrives).
    public func replaceRoutes(with routes: [RouteDTO]) throws {
        try delete(model: RouteRecord.self)
        for r in routes { insert(RouteRecord(r)) }
        try save()
    }

    public func allRouteDTOs() throws -> [RouteDTO] {
        try fetch(FetchDescriptor<RouteRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])).map(\.dto)
    }
}
