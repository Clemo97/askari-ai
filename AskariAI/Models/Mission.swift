import Foundation
import CoreLocation
import PowerSync

// MARK: - Mission

struct Mission: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var objectives: String
    var startDate: Date
    var endDate: Date
    var patrolType: PatrolType
    var status: MissionStatus
    var missionState: MissionState
    var staffIds: [UUID]
    var leaderId: UUID
    var selectedBlockIds: [UUID]
    var parkId: UUID
    var createdBy: UUID
    var createdAt: Date

    enum PatrolType: String, Codable, CaseIterable {
        case fenceBoundary = "Fence/Boundary"
        case local = "Local"
        case mobile = "Mobile"
        case aerial = "Aerial"
        case waterway = "Waterway"
    }

    enum MissionStatus: String, Codable {
        case current, future, past
    }

    enum MissionState: String, Codable {
        case notStarted = "not_started"
        case active
        case paused
        case completed
    }
}

// MARK: - PowerSync cursor → Mission

extension Mission {
    init?(cursor: any SqlCursor) {
        guard
            let idStr = try? cursor.getString(name: "id"), let id = UUID(uuidString: idStr),
            let name = try? cursor.getString(name: "name"),
            let startDateStr = try? cursor.getString(name: "start_date"),
            let startDate = SystemManager.parseDate(startDateStr),
            let endDateStr = try? cursor.getString(name: "end_date"),
            let endDate = SystemManager.parseDate(endDateStr),
            let leaderStr = try? cursor.getString(name: "leader_id"), let leaderId = UUID(uuidString: leaderStr),
            let parkStr = try? cursor.getString(name: "park_id"), let parkId = UUID(uuidString: parkStr),
            let createdByStr = try? cursor.getString(name: "created_by"), let createdBy = UUID(uuidString: createdByStr),
            let createdAtStr = try? cursor.getString(name: "created_at"), let createdAt = SystemManager.parseDate(createdAtStr)
        else { return nil }

        let staffIdsJSON = (try? cursor.getStringOptional(name: "staff_ids")) ?? "[]"
        let blockIdsJSON = (try? cursor.getStringOptional(name: "selected_block_ids")) ?? "[]"

        self.id = id
        self.name = name
        self.objectives = (try? cursor.getStringOptional(name: "objectives")) ?? ""
        self.startDate = startDate
        self.endDate = endDate
        self.patrolType = PatrolType(rawValue: (try? cursor.getStringOptional(name: "patrol_type")) ?? "") ?? .local
        self.status = MissionStatus(rawValue: (try? cursor.getStringOptional(name: "status")) ?? "current") ?? .current
        self.missionState = MissionState(rawValue: (try? cursor.getStringOptional(name: "mission_state")) ?? "not_started") ?? .notStarted
        self.staffIds = (try? JSONDecoder().decode([UUID].self, from: Data((staffIdsJSON ?? "[]").utf8))) ?? []
        self.leaderId = leaderId
        self.selectedBlockIds = (try? JSONDecoder().decode([UUID].self, from: Data((blockIdsJSON ?? "[]").utf8))) ?? []
        self.parkId = parkId
        self.createdBy = createdBy
        self.createdAt = createdAt
    }
}

// MARK: - MissionScore

struct MissionScore: Identifiable, Equatable, Codable {
    let id: UUID
    let missionId: UUID
    var distanceTraveledKm: Double
    var bufferPoints: Double
    var incidentPoints: Double
    var missionCompleted: Bool
    var completedAt: Date?
}

// MARK: - RoutePoint

struct RoutePoint: Codable {
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let accuracy: Double

    enum CodingKeys: String, CodingKey {
        case latitude, longitude, timestamp, accuracy
    }

    init(coordinate: CLLocationCoordinate2D, timestamp: Date, accuracy: Double) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.accuracy = accuracy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lat = try container.decode(Double.self, forKey: .latitude)
        let lon = try container.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        accuracy = try container.decode(Double.self, forKey: .accuracy)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(coordinate.latitude, forKey: .latitude)
        try container.encode(coordinate.longitude, forKey: .longitude)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(accuracy, forKey: .accuracy)
    }
}

extension RoutePoint: Equatable {
    static func == (lhs: RoutePoint, rhs: RoutePoint) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.timestamp == rhs.timestamp &&
        lhs.accuracy == rhs.accuracy
    }
}
