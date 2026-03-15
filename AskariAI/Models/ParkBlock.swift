import Foundation
import CoreLocation
import PowerSync

// MARK: - ParkBlock

struct ParkBlock: Identifiable, Codable {
    let id: UUID
    var blockName: String
    var coordinates: [CLLocationCoordinate2D]
    var threshold: Double           // % coverage target
    var visibility: Double          // meters
    var rateOfDecay: Double         // days
    var lastPatrolled: Date?
    var parkId: UUID
    var createdAt: Date

    var healthScore: Double {
        guard let last = lastPatrolled else { return 0 }
        let daysSince = Date().timeIntervalSince(last) / 86400
        return max(0, 1.0 - (daysSince / rateOfDecay))
    }

    var isOverdue: Bool { healthScore < threshold / 100 }

    enum CodingKeys: String, CodingKey {
        case id, blockName, threshold, visibility, rateOfDecay, lastPatrolled, parkId, createdAt
        case coordinatePoints
    }

    init(
        id: UUID = UUID(),
        blockName: String,
        coordinates: [CLLocationCoordinate2D],
        threshold: Double = 0.7,
        visibility: Double = 200,
        rateOfDecay: Double = 7,
        lastPatrolled: Date? = nil,
        parkId: UUID,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.blockName = blockName
        self.coordinates = coordinates
        self.threshold = threshold
        self.visibility = visibility
        self.rateOfDecay = rateOfDecay
        self.lastPatrolled = lastPatrolled
        self.parkId = parkId
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        blockName = try c.decode(String.self, forKey: .blockName)
        threshold = try c.decode(Double.self, forKey: .threshold)
        visibility = try c.decode(Double.self, forKey: .visibility)
        rateOfDecay = try c.decode(Double.self, forKey: .rateOfDecay)
        lastPatrolled = try c.decodeIfPresent(Date.self, forKey: .lastPatrolled)
        parkId = try c.decode(UUID.self, forKey: .parkId)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        let points = try c.decode([[Double]].self, forKey: .coordinatePoints)
        coordinates = points.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(blockName, forKey: .blockName)
        try c.encode(threshold, forKey: .threshold)
        try c.encode(visibility, forKey: .visibility)
        try c.encode(rateOfDecay, forKey: .rateOfDecay)
        try c.encodeIfPresent(lastPatrolled, forKey: .lastPatrolled)
        try c.encode(parkId, forKey: .parkId)
        try c.encode(createdAt, forKey: .createdAt)
        let points = coordinates.map { [$0.longitude, $0.latitude] }
        try c.encode(points, forKey: .coordinatePoints)
    }
}

// MARK: - PowerSync row → ParkBlock

extension ParkBlock {
    init?(row: [String: String?]) {
        guard
            let idStr = row["id"] as? String, let id = UUID(uuidString: idStr),
            let blockName = row["block_name"] as? String,
            let parkStr = row["park_id"] as? String, let parkId = UUID(uuidString: parkStr),
            let createdAtStr = row["created_at"] as? String, let createdAt = SystemManager.parseDate(createdAtStr)
        else { return nil }

        let coordsJSON = row["coordinates"] as? String ?? "[]"
        let rawCoords = (try? JSONDecoder().decode([[Double]].self, from: Data(coordsJSON.utf8))) ?? []
        let coords = rawCoords.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }

        self.init(
            id: id,
            blockName: blockName,
            coordinates: coords,
            threshold: Double(row["threshold"] as? String ?? "0.7") ?? 0.7,
            visibility: Double(row["visibility"] as? String ?? "200") ?? 200,
            rateOfDecay: Double(row["rate_of_decay"] as? String ?? "7") ?? 7,
            lastPatrolled: SystemManager.parseDate(row["last_patrolled"] as? String),
            parkId: parkId,
            createdAt: createdAt
        )
    }
}

extension ParkBlock: Equatable {
    static func == (lhs: ParkBlock, rhs: ParkBlock) -> Bool {
        lhs.id == rhs.id &&
        lhs.blockName == rhs.blockName &&
        lhs.threshold == rhs.threshold &&
        lhs.visibility == rhs.visibility &&
        lhs.rateOfDecay == rhs.rateOfDecay &&
        lhs.lastPatrolled == rhs.lastPatrolled &&
        lhs.parkId == rhs.parkId &&
        lhs.createdAt == rhs.createdAt &&
        lhs.coordinates.count == rhs.coordinates.count &&
        zip(lhs.coordinates, rhs.coordinates).allSatisfy {
            $0.latitude == $1.latitude && $0.longitude == $1.longitude
        }
    }
}

// MARK: - PowerSync cursor → ParkBlock

extension ParkBlock {
    init?(cursor: any SqlCursor) {
        guard
            let idStr = try? cursor.getString(name: "id"), let id = UUID(uuidString: idStr),
            let blockName = try? cursor.getString(name: "block_name"),
            let parkStr = try? cursor.getString(name: "park_id"), let parkId = UUID(uuidString: parkStr),
            let createdAtStr = try? cursor.getString(name: "created_at"), let createdAt = SystemManager.parseDate(createdAtStr)
        else { return nil }

        let coordsJSON = (try? cursor.getStringOptional(name: "coordinates")) ?? "[]"
        let rawCoords = (try? JSONDecoder().decode([[Double]].self, from: Data((coordsJSON ?? "[]").utf8))) ?? []
        let coords = rawCoords.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }

        self.init(
            id: id,
            blockName: blockName,
            coordinates: coords,
            threshold: Double((try? cursor.getStringOptional(name: "threshold")) ?? "0.7") ?? 0.7,
            visibility: Double((try? cursor.getStringOptional(name: "visibility")) ?? "200") ?? 200,
            rateOfDecay: Double((try? cursor.getStringOptional(name: "rate_of_decay")) ?? "7") ?? 7,
            lastPatrolled: SystemManager.parseDate((try? cursor.getStringOptional(name: "last_patrolled")) ?? nil),
            parkId: parkId,
            createdAt: createdAt
        )
    }
}
